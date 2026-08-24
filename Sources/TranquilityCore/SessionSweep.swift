import Foundation

/// What is gone, what is retired, and what is worth saying about it.
///
/// Dead sessions accumulate forever — 200 here, 157 of them from a single
/// afternoon of prompt-replay runs — and the sweep touched every one on every
/// poll, writing a line each time: ~250 lines/second, 38.5M lines, 2.3 GB in
/// five days. A log that large buries the diagnostics it exists to provide.
///
/// Five rules, in the order they matter:
///
/// 1. **Liveness governs.** A session is retired only while the agents API says
///    it is gone, and the instant it reappears it is un-retired and said out
///    loud. Nothing else may retire a session — not age, not silence, not event
///    count — because nothing else is evidence that no one is there to answer.
///    This is the rule that keeps the tty filter's failure from repeating: that
///    one inferred "nobody is here" from a proxy, and hid real conversations.
///    Measured while designing this: every replay session carries a tty,
///    inherited from the terminal that launched the harness.
/// 2. **Retirement is timed, not counted.** The liveness probe is cached for six
///    seconds, so consecutive polls can be one observation; counting them would
///    retire a session on a single probe wearing three hats.
/// 3. **Only observed absence ages a session.** A gap in sweeping — a probe
///    outage, a laptop asleep, the app paused — is not evidence, so a gap longer
///    than `gapTolerance` restarts every absence clock. Without this the wall
///    clock did the ageing: two observations five minutes apart across an outage
///    retired a session that had been watched exactly twice.
/// 4. **What is said is symmetric.** Anything announced gone is announced again
///    when it returns, retired or not. A log that says a session died and never
///    retracts it sends the next debugger down a hole.
/// 5. **State is in memory, so a restart forgets.** Deliberate: the worst case is
///    re-observing sessions already known dead, the same fail-open posture as the
///    probe. Persisted, a bug here could bury a live session across restarts.
///
/// Durations use a monotonic clock. These are elapsed times, and a wall clock
/// steps — an NTP correction backwards froze retirement and silenced the
/// heartbeat for the length of the step.
///
/// Extracted from `Coordinator` (23 Aug, Coordinator-split rider) into its own
/// injectable type — the audit's own naming for the smell this fixes:
/// "sweep statics become injectable — resetSweepStateForTesting is the
/// smell." Before this, the state below lived as `private nonisolated(unsafe)
/// static var` properties on `Coordinator` itself, shared globally across
/// every `Coordinator` value in the process — correct for production (one
/// sweep memory per app run, however many `Coordinator` structs get
/// constructed around the same store) but the reason `SweepTests` needed a
/// global `resetSweepStateForTesting()` call in every `setUp`/`tearDown`
/// rather than simply constructing a fresh instance. `SessionSweep.shared`
/// preserves the exact production behavior (one shared instance, the same
/// static-var semantics as before); a test now injects its own
/// `SessionSweep()` instead of resetting a global.
public final class SessionSweep: @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant

    /// One record per session. Unified rather than an `absent` map beside a
    /// `retired` set, because two structures describing one lifecycle drift:
    /// the pair could say a session was both retired and freshly absent.
    private struct Watch {
        var since: Instant       // start of the CURRENT observed absence
        var lastSeen: Instant    // last sweep that saw this session at all
        var announced = false    // "gone" has been said, so say "back" if it returns
        var retired = false
    }
    private var watched: [String: Watch] = [:]
    private var lastSweep: Instant?
    private var lastHeartbeat: Instant?
    private var probeFailingSince: Instant?
    private let lock = NSLock()

    /// Long enough that a slow probe or a tab being cycled cannot retire a session
    /// someone is using; short enough that a finished batch run stops being swept
    /// while you are still in the same coffee.
    private let retirementDelay: Duration = .seconds(120)
    /// 288 lines a day. The transitions say what changed; this says what IS.
    private let heartbeatInterval: Duration = .seconds(300)
    /// Normal polling is every 1–5s, so a longer gap means the app was not watching.
    private let gapTolerance: Duration = .seconds(30)
    /// `waitingSessions()` is `LIMIT 200`, so a session can leave the result set
    /// without leaving the queue. Forgetting on that basis re-announced older dead
    /// sessions every time a newer one was dismissed and slid one back into view,
    /// and retirement never converged. Records expire on their own clock instead.
    private let watchRetention: Duration = .seconds(3600)

    /// The default every `Coordinator` uses — one sweep memory per process,
    /// the same guarantee the old static state gave for free. Not `private`:
    /// a caller outside `Coordinator`'s own init that wants the production
    /// memory explicitly (rather than accepting the default) can still name it.
    public static let shared = SessionSweep()

    public init() {}

    /// Retired right now, for assertions. Not used in production.
    func retiredSessionsForTesting() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(watched.filter(\.value.retired).keys)
    }

    /// The probe could not answer. Said on the way in and then at heartbeat cadence,
    /// never per poll: `sessions()` caches only successes, so during an outage every
    /// single call re-spawns the subprocess AND wrote a line — the 2.3 GB shape again
    /// on the branch beside the one that caused it.
    func noteProbeFailure(now: Instant = .now, trace: (@Sendable (String) -> Void)?) {
        var line: String?
        do {
            lock.lock()
            defer { lock.unlock() }
            if let since = probeFailingSince {
                if now - (lastHeartbeat ?? since) >= heartbeatInterval {
                    lastHeartbeat = now
                    line = "liveness probe still failing after "
                         + "\(Int((now - since).components.seconds))s; failing open, "
                         + "\(watched.count) sessions unwatched"
                }
            } else {
                probeFailingSince = now
                lastHeartbeat = now
                line = "liveness probe failed; failing open (every session treated as live)"
            }
        }
        if let line { trace?(line) }
    }

    func sweep(_ all: [WaitingSession], live: Set<String>, now: Instant = .now,
               trace: (@Sendable (String) -> Void)?) {
        // Collected under the lock, spoken after it. `trace` writes to app.log with a
        // synchronous open/write/close, and every caller of `waiting()` is on the main
        // actor — so lines emitted in place are file I/O on the UI thread. That is the
        // same stall this app already learned from the liveness probe, which had to be
        // moved off-main because "called synchronously from the main actor it froze the
        // UI on every tick". Two hundred writes in one sweep is that mistake again.
        var gone: [String] = []
        var retiredNow: [String] = []
        var revived: [String] = []
        var longestGone = 0
        var recovered: String?
        var heartbeat: String?

        do {
            lock.lock()
            defer { lock.unlock() }

            if let failingSince = probeFailingSince {
                recovered = "liveness probe recovered after "
                          + "\(Int((now - failingSince).components.seconds))s"
                probeFailingSince = nil
            }
            // Rule 3: a gap means nobody was watching, so no absence observed across
            // it may count toward retirement.
            let blind = lastSweep.map { now - $0 > gapTolerance } ?? true
            lastSweep = now

            for session in all {
                let id = session.sessionId
                guard !live.contains(id) else {
                    // Answerable now, whatever it was a moment ago. Rule 4: if we said
                    // it was gone, we say it is back — retired or merely absent.
                    if let watch = watched.removeValue(forKey: id), watch.announced {
                        revived.append(session.projectLabel)
                    }
                    continue
                }
                var watch = watched[id] ?? Watch(since: now, lastSeen: now)
                if blind { watch.since = now }        // the gap is not evidence
                watch.lastSeen = now
                defer { watched[id] = watch }

                guard !watch.retired else { continue }   // accounted for; say nothing
                if !watch.announced {
                    gone.append(session.projectLabel)
                    watch.announced = true
                }
                let elapsed = now - watch.since
                if elapsed >= retirementDelay {
                    watch.retired = true
                    retiredNow.append(session.projectLabel)
                    longestGone = max(longestGone, Int(elapsed.components.seconds))
                }
            }

            // Records expire on their own clock, NOT on absence from a truncated
            // query — see `watchRetention`.
            watched = watched.filter { now - $0.value.lastSeen < watchRetention }

            // Nil means this is the first sweep, which is exactly when the state is
            // most worth stating — so it beats immediately rather than in five minutes.
            if lastHeartbeat.map({ now - $0 >= heartbeatInterval }) ?? true {
                lastHeartbeat = now
                let liveCount = all.count { live.contains($0.sessionId) }
                let retiredCount = watched.count(where: \.value.retired)
                heartbeat = "sweep: \(liveCount) live, \(retiredCount) retired, "
                          + "\(watched.count - retiredCount) going, "
                          + "\(all.count) in the newest-200 window"
            }
        }

        if let recovered { trace?(recovered) }
        // Both shapes lead with "skipping" so one grep finds every skip, whether it
        // was a lone session or two hundred collapsed into a count.
        if let line = Self.phrase(gone, one: { "skipping \($0): session is gone" },
                                  many: { "skipping \($0) sessions, all gone: \($1)" }) {
            trace?(line)
        }
        if let line = Self.phrase(retiredNow,
                                  one: { "retired \($0) after \(longestGone)s gone" },
                                  many: { "retired \($0) sessions after \(longestGone)s gone: \($1)" }) {
            trace?(line)
        }
        if let line = Self.phrase(revived, one: { "\($0) is live again" },
                                  many: { "\($0) sessions live again: \($1)" }) { trace?(line) }
        if let heartbeat { trace?(heartbeat) }
    }

    /// One line whether it is one session or two hundred.
    ///
    /// At scale the information is *which projects and how many*, not two hundred
    /// repetitions of the same sentence — and since each line is a synchronous write
    /// on the main thread, collapsing them is a latency fix as much as a legibility
    /// one. A single session still reads as a sentence, because that is the case you
    /// are usually actually debugging.
    private static func phrase(_ labels: [String],
                               one: (String) -> String,
                               many: (Int, String) -> String) -> String? {
        guard let first = labels.first else { return nil }
        guard labels.count > 1 else { return one(first) }
        let counts = Dictionary(grouping: labels, by: { $0 })
            .map { (label: $0.key, count: $0.value.count) }
            .sorted { ($0.count, $1.label) > ($1.count, $0.label) }
        let shown = counts.prefix(5).map { "\($0.label)×\($0.count)" }.joined(separator: ", ")
        let hidden = counts.count - min(5, counts.count)
        return many(labels.count, hidden > 0 ? "\(shown), +\(hidden) more" : shown)
    }
}
