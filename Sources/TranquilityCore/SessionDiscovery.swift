import Foundation

/// Every session this machine has run lately, awake or not.
///
/// Ruled 11 Aug: "They are equally valid agents whether or not they are awake.
/// They do not stop existing once their process ends, and their history should
/// not be invisible or unreachable." The grid until now enumerated PROCESSES —
/// `claude agents --json` joined against the store — so a machine restart
/// emptied it completely, on precisely the morning a list is most wanted.
///
/// So the direction inverts. The transcript directory enumerates, because it is
/// the durable record and Claude Code writes it whether we are watching or not.
/// Liveness becomes a column on a row rather than the gate in front of it.
///
/// Read-only by construction: no store writes, nothing spoken, no synthetic
/// events. This is a display source, not a log source — the rule that keeps
/// "an event is a fact about what happened, and facts do not change" intact.
public enum SessionDiscovery {

    // MARK: - What a row is

    /// Three states, not two, and the third is the one that matters.
    ///
    /// A failed probe is not evidence of absence. Collapsing `unknown` into
    /// `gone` would offer a revive on a session that is merely unproven — and
    /// `claude --resume` on a session that is still running leaves the original
    /// process alive and adds a SECOND live entry under the same id, which
    /// crashed the app twice (06 Aug 14:35, 07 Aug 17:39; see the dedupe note
    /// in the app's `sessionRowsNow`). The verb must have positive evidence.
    public enum Liveness: String, Sendable, Equatable {
        case live, gone, unknown
    }

    public struct Session: Sendable, Equatable {
        public let sessionId: String
        /// Where the session was launched, read from the transcript rather than
        /// decoded from the directory name — see `firstCwd`.
        public let cwd: String?
        public let transcriptPath: String
        public let title: String?
        /// When this agent last moved: the newest timestamp the conversation
        /// itself wrote, with the file's mtime only as the fallback for a tail
        /// holding no dated entry at all. NOT the file's clock — see
        /// `lastMoved(tail:)` for why mtime cannot be trusted to mean this.
        public let lastActivityAt: Date
        /// Whether a user prompt follows the final assistant message. NOT the
        /// same question as "have you heard it", which lives in the cursor and
        /// is a fact about the user rather than the world.
        public let answered: Bool
        public let activity: SessionActivity?
        public let liveness: Liveness
        /// `gone` AND `landingDirectory` finds somewhere to stand — the
        /// original directory, else its repository root, else `~/Projects`.
        /// Never true on `unknown`, and never true when `claude --resume`
        /// would land nowhere (a temp path the OS has reaped, and nothing
        /// above it). Codex rows read this differently — see `discoverCodex`.
        public let revivable: Bool
        /// `HarnessAdapter.id` ("claude-code", "codex") — what `reviveCommand`
        /// looks the adapter up by. Defaulted for every pre-existing
        /// construction site (all of them Claude Code, from before discovery
        /// went multi-harness), so nothing else needed to change to add this.
        public let harness: String

        public init(sessionId: String, cwd: String?, transcriptPath: String,
                    title: String?, lastActivityAt: Date, answered: Bool,
                    activity: SessionActivity?, liveness: Liveness, revivable: Bool,
                    harness: String = ClaudeCodeAdapter().id) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.transcriptPath = transcriptPath
            self.title = title
            self.lastActivityAt = lastActivityAt
            self.answered = answered
            self.activity = activity
            self.liveness = liveness
            self.revivable = revivable
            self.harness = harness
        }

        /// The same row with the process facts joined on. The scan leaves them
        /// at `.unknown`/`false` because it is cached and they are not.
        func with(liveness: Liveness, revivable: Bool) -> Session {
            Session(sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath,
                    title: title, lastActivityAt: lastActivityAt, answered: answered,
                    activity: activity, liveness: liveness, revivable: revivable,
                    harness: harness)
        }

        /// What brings this session back. Nil when it must not be offered.
        /// The resume flag comes from the adapter now — this used to be a
        /// second, independent `["--resume", sessionId]` literal that could
        /// drift from `AgentDefaults`'s, and did not even have the shape to
        /// represent a subcommand-style resume (Codex: `resume <id>`, not a
        /// flag). Per-row adapter lookup by `harness`, landed alongside
        /// `discoverCodex`.
        ///
        /// For a Codex row specifically, prefer
        /// `SessionLauncher.attemptCodexResume` over blindly launching this
        /// tuple: Codex's single-writer lock means a plain launch can lose a
        /// race a still-live session is holding, and only `attemptCodexResume`
        /// reads which outcome actually happened. This property still
        /// answers "what command, if any" — the settled design's decision
        /// tree (try it, read Codex's own answer) is the caller's to run.
        public var reviveCommand: (cwd: String, arguments: [String])? {
            // The LANDING directory, not the recorded one — they differ exactly
            // when the original is gone, which is the case this exists for.
            guard revivable, let cwd = SessionDiscovery.landingDirectory(for: cwd)
            else { return nil }
            let adapter: any HarnessAdapter = harness == CodexAdapter().id
                ? CodexAdapter() : ClaudeCodeAdapter()
            return (cwd, adapter.resumeArguments(sessionId: sessionId))
        }
    }

    /// Counts travel with the rows, because a filter that drops 460 of 504
    /// candidates in silence reads as "that is all of them" — the same lie the
    /// empty panel tells today.
    public struct Result: Sendable {
        public var sessions: [Session] = []
        public var scanned = 0
        /// Excluded as headless: `entrypoint` is `sdk-cli` rather than `cli`.
        public var headless = 0
        /// The transcript carries no `entrypoint` at all, so it was KEPT rather
        /// than dropped — exclusion needs positive evidence. Zero on every file
        /// on this machine as of 11 Aug; counted anyway, because a silent zero
        /// and a silent thousand look identical.
        public var unclassifiable = 0
        /// Ran in a directory the OS reaps — a drill fixture, not an agent.
        /// Counted rather than silently dropped, for the same reason every
        /// other exclusion here is: a silent zero and a silent thousand look
        /// identical.
        public var temporary = 0
        /// Dropped by `limit` after ranking, so the caller can say "and more".
        public var beyondLimit = 0
        /// The liveness probe could not answer, so every row is `unknown`.
        public var livenessUnavailable = false
    }

    // MARK: - Scope

    /// A week rather than a day, decided by counting rather than by argument:
    /// on this machine the window holds 31 interactive sessions at 24h and 44
    /// at 7d. Thirteen more rows buys "what I have been doing" over "what I was
    /// doing", which is what makes the case work after a weekend.
    public static let defaultWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Above what any list can be read at. The grid caps far lower; this only
    /// stops the classifier reading the whole archive.
    public static let defaultLimit = 60

    /// Enough to reach the first entry carrying `entrypoint` and `cwd`. The
    /// first lines of a transcript can be bookkeeping (`queue-operation`,
    /// `last-prompt`) which carry neither.
    static let headBytes = 64 * 1024

    /// A single record can be larger than the whole window: a queued prompt
    /// carrying a long payload writes one `queue-operation` line of 200KB, and
    /// two files on this machine open with exactly that, so the first window
    /// held two lines and neither had an `entrypoint`. They were counted
    /// unclassifiable and dropped — correctly, as it happens, since both were
    /// cron sessions, but by luck rather than by rule. One escalation, then the
    /// file is genuinely unreadable and says so.
    static let headBytesEscalated = 2 * 1024 * 1024

    // MARK: - The walk

    /// The disk half, cached; the process half, never.
    ///
    /// This is the "liveness is a column, not a gate" decision earning its
    /// keep. The grid refreshes on every intake tick, and re-walking 505
    /// transcripts each time would be absurd — but the expensive facts (which
    /// sessions exist, what they are called, whether you answered them) change
    /// on the timescale of a conversation, while the cheap one (is a process
    /// behind it) changes in an instant and must never be stale. So the scan is
    /// cached and the liveness join is redone on every call.
    ///
    /// A session that exits therefore turns from a live row into a closed row
    /// on the very next tick, without any disk work at all: it is already in
    /// the cached scan, because the scan does not care whether it was running.
    private final class ScanCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (key: String, at: Date, result: Result)?
        /// The directory is part of the key, not just the window and the cap.
        /// Without it a test archive answers for the real one, which is a bug
        /// waiting to be blamed on the classifier.
        static func key(_ window: TimeInterval, _ limit: Int, _ projects: URL) -> String {
            "\(window)|\(limit)|\(projects.path)"
        }
        /// The last scan for this archive at ANY age, plus whether it is old
        /// enough to be worth redoing. Serving is not the same question as
        /// refreshing, and conflating them is what made the closed rows blink:
        /// returning nothing on expiry emptied the band for the five seconds a
        /// rescan took, every thirty seconds, forever.
        func get(key: String, now: Date, ttl: TimeInterval) -> (result: Result, stale: Bool)? {
            lock.lock(); defer { lock.unlock() }
            guard let value, value.key == key else { return nil }
            let age = now.timeIntervalSince(value.at)
            return (value.result, age >= ttl || age < 0)
        }
        func put(key: String, now: Date, result: Result) {
            lock.lock(); value = (key, now, result); lock.unlock()
        }
        /// One background walk at a time. Without this, every tick of a 1–5s
        /// poll would start another scan of the same archive while the first
        /// was still running.
        private var refreshing: Set<String> = []
        func beginRefresh(key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return refreshing.insert(key).inserted
        }
        func endRefresh(key: String) {
            lock.lock(); refreshing.remove(key); lock.unlock()
        }
        var isRefreshing: Bool {
            lock.lock(); defer { lock.unlock() }; return !refreshing.isEmpty
        }
    }
    private static let scans = ScanCache()

    /// Long enough that the walk is not on the poll's critical path, short
    /// enough that a session started in another terminal shows up while you are
    /// still looking for it.
    public static let scanTTL: TimeInterval = 30

    /// For callers that must not block: the liveness-joined rows IF a scan is
    /// already in hand, and otherwise nothing at all plus a refresh started in
    /// the background.
    ///
    /// The grid refresh runs on the main thread. A cold `discover` walks the
    /// archive and takes about a second and a half on this machine, and a
    /// second and a half of frozen panel is a worse bug than the empty panel
    /// this feature exists to fix. So the first tick after launch shows the
    /// live sessions alone — exactly what shipped before — and the closed rows
    /// arrive on the next one. Nothing is lost by being a tick late to
    /// something that has not moved in hours.
    ///
    /// The liveness join still happens inline on every call, because it is a
    /// cached subprocess result and costs nothing.
    public static func discoverIfScanned(
        window: TimeInterval = defaultWindow,
        limit: Int = defaultLimit,
        now: Date = Date(),
        live: ClaudeAgentsReading = ClaudeAgentsCLI(),
        projects: URL = TranscriptArchive.projectsDirectory,
        titles: TranscriptTitles = TranscriptTitles.shared,
        ttl: TimeInterval = scanTTL
    ) -> Result? {
        let key = ScanCache.key(window, limit, projects)
        let held = scans.get(key: key, now: now, ttl: ttl)

        // Refresh whenever there is nothing or the answer has aged out — but
        // that decision never withholds what we already have.
        if held == nil || held?.stale == true, scans.beginRefresh(key: key) {
            Task.detached(priority: .utility) {
                let fresh = scan(window: window, limit: limit, now: Date(),
                                 projects: projects, titles: titles)
                scans.put(key: key, now: Date(), result: fresh)
                scans.endRefresh(key: key)
            }
        }

        // Stale is fine and nil is not. These are sessions that exited hours
        // ago: a thirty-second-old answer about them is indistinguishable from
        // a current one, while an EMPTY answer is a row disappearing out from
        // under someone who was looking at it. Only a genuinely cold cache —
        // the first tick after launch — returns nothing.
        guard let held else { return nil }
        return join(held.result, live: live)
    }

    /// Whether the archive has been read at all yet, at any age.
    ///
    /// `discoverIfScanned` returns nothing on a cold cache by design, and the
    /// warm runs off-main, so for the first seconds after a launch there is a
    /// real difference between "no closed sessions" and "not measured yet".
    /// Past Agents could not tell them apart and reported the first: it said
    /// "0 sessions · 7 days" for a beat after every relaunch, and this app
    /// relaunches on every merge (31 Aug, found by photographing the list a
    /// second after launch). An empty answer presented as a finished one is
    /// the same `gone` versus `unknown` confusion this file already refuses
    /// everywhere else.
    public static func hasScanned(
        window: TimeInterval = defaultWindow,
        limit: Int = defaultLimit,
        projects: URL = TranscriptArchive.projectsDirectory
    ) -> Bool {
        scans.get(key: ScanCache.key(window, limit, projects),
                  now: Date(), ttl: .greatestFiniteMagnitude) != nil
    }

    /// Wait for any background scan to finish. For tests only.
    ///
    /// A detached scan that outlives its test keeps doing disk I/O while the
    /// next suite runs, and the next suite here measures real-time audio
    /// playback — `SessionDiscoveryTests` sorts immediately before
    /// `TruncationTests`. That made a timing test fail in a way that looked
    /// like a defect in speech and was actually this.
    public static func settleForTesting(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while scans.isRefreshing, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Fill the cache off-main so the first painted grid already has its closed
    /// rows. Without this the panel opens with live sessions alone and they
    /// arrive a few seconds later, which is the same blink in miniature.
    public static func warm(
        window: TimeInterval = defaultWindow,
        limit: Int = defaultLimit,
        projects: URL = TranscriptArchive.projectsDirectory,
        titles: TranscriptTitles = TranscriptTitles.shared
    ) {
        let key = ScanCache.key(window, limit, projects)
        guard scans.get(key: key, now: Date(), ttl: scanTTL) == nil,
              scans.beginRefresh(key: key) else { return }
        let result = scan(window: window, limit: limit, now: Date(),
                          projects: projects, titles: titles)
        scans.put(key: key, now: Date(), result: result)
        scans.endRefresh(key: key)
    }

    public static func discover(
        window: TimeInterval = defaultWindow,
        limit: Int = defaultLimit,
        now: Date = Date(),
        live: ClaudeAgentsReading = ClaudeAgentsCLI(),
        projects: URL = TranscriptArchive.projectsDirectory,
        titles: TranscriptTitles = TranscriptTitles.shared,
        ttl: TimeInterval = scanTTL,
        /// See `scan`. A fixture-based caller passes `[]` so its own temp
        /// directory is not mistaken for a drill's.
        temporaryRoots: [String] = defaultTemporaryRoots
    ) -> Result {
        let key = ScanCache.key(window, limit, projects)
        let held = scans.get(key: key, now: now, ttl: ttl)
        let result: Result = {
            if let held, !held.stale { return held.result }
            let scanned = scan(window: window, limit: limit, now: now,
                               projects: projects, titles: titles,
                               temporaryRoots: temporaryRoots)
            scans.put(key: key, now: now, result: scanned)
            return scanned
        }()

        return join(result, live: live)
    }

    /// The process half, redone on every call however old the scan is.
    static func join(_ scanned: Result, live: ClaudeAgentsReading) -> Result {
        var result = scanned
        // nil means "could not determine", which is not "none" — the same
        // distinction `ClaudeAgentsReading` documents. Here it makes every row
        // `unknown`, which shows the work and withholds the verb.
        let liveIds = live.sessions().map { Set($0.map(\.sessionId)) }
        result.livenessUnavailable = liveIds == nil
        let fm = FileManager.default
        result.sessions = result.sessions.map { session in
            let liveness: Liveness = {
                guard let liveIds else { return .unknown }
                return liveIds.contains(session.sessionId) ? .live : .gone
            }()
            // A directory that no longer exists is where `--resume` fails with
            // "No conversation found" (BloopAI/vibe-kanban#2993 is the same
            // failure with their filenames). Resolve first, offer second, and
            // resolve it HERE rather than in the scan: a directory can vanish
            // between two ticks and an offer must never outlive its target.
            let landable = landingDirectory(for: session.cwd, fm) != nil
            return session.with(liveness: liveness,
                                revivable: liveness == .gone && landable)
        }
        return result
    }

    /// The disk walk. Everything here is a fact about what was written, so it
    /// is safe to cache; nothing here consults a process.
    static func scan(
        window: TimeInterval,
        limit: Int,
        now: Date,
        projects: URL,
        titles: TranscriptTitles,
        /// Injectable so a test can build fixtures where tests build things —
        /// in a temp directory — without being filtered out by the very rule
        /// it is checking. Empty means "exclude nothing", which is what every
        /// existing fixture-based test wants and is why they pass it.
        temporaryRoots: [String] = defaultTemporaryRoots
    ) -> Result {
        var result = Result()
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil) else { return result }

        var candidates: [(URL, Date)] = []
        for project in projectDirs {
            // Immediate children only. A session's subagent traffic lives in
            // `<sessionId>/subagents/*.jsonl` — 7,265 files on this machine
            // against 2,634 sessions — and a subagent is not an agent you can
            // talk to.
            guard let files = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                // mtime stays as the PRE-filter only. An append-only file's
                // clock can only run ahead of its last written timestamp, so
                // nothing inside the real window is lost to this test — but
                // membership and rank are decided by `lastMoved`, below.
                guard now.timeIntervalSince(modified) <= window else { continue }
                candidates.append((file, modified))
            }
        }

        var kept: [Session] = []
        for (url, modified) in candidates.sorted(by: { $0.1 > $1.1 }) {
            result.scanned += 1
            let path = url.path
            guard let head = classifiableHead(of: path) else { continue }

            // The one field that separates a person's session from a robot's,
            // and unlike the tty it is on disk, so it survives the process.
            let entry = entrypoint(head: head)
            if entry == nil { result.unclassifiable += 1 }
            guard !isHeadless(entry) else { result.headless += 1; continue }
            // A session that ran in a directory the OS reaps is a fixture,
            // not an agent. `isTemporary` already governs whether one may be
            // REVIVED — "nothing real runs there, so nothing real is lost by
            // refusing to reopen there" — but nothing stopped it being
            // LISTED, and the list is where it does the damage.
            //
            // Measured 26 Aug: the live-TUI drill launches a real interactive
            // `claude` in /private/tmp and was run some twenty-five times in
            // an afternoon. Its transcripts are indistinguishable from a real
            // session's — same `entrypoint: cli` — so `isHeadless` waves them
            // through, and Past Agents filled with rows named MARKER-ONE
            // while the user's own work scrolled off the bottom. Nine of the
            // ten visible rows were test fixtures.
            //
            let sessionId = url.deletingPathExtension().lastPathComponent
            let tail = SessionActivity.tail(of: path) ?? []
            let cwd = firstCwd(head: head, tail: tail)
            // Same predicate as the revive guard, one gate earlier.
            guard !isTemporary(cwd ?? "", temporaryRoots) else {
                result.temporary += 1
                continue
            }
            let moved = lastMoved(tail: tail) ?? modified

            // The window re-applied to the conversation's own clock: a touched
            // ancient transcript wears a fresh mtime — that is exactly the
            // contamination — but its last written entry is still weeks old,
            // and scope is defined by when the agent moved, not by when its
            // file did.
            guard now.timeIntervalSince(moved) <= window else { continue }

            // Liveness and revivability are deliberately absent here: they are
            // process facts, they go stale in seconds, and `discover` joins
            // them on afterwards so this whole walk can be cached.
            kept.append(Session(
                sessionId: sessionId,
                cwd: cwd,
                transcriptPath: path,
                title: titles.latestTitle(transcriptPath: path),
                lastActivityAt: moved,
                answered: isAnswered(tail: tail),
                activity: SessionActivity.classify(tail: tail, modified: modified, now: now),
                liveness: .unknown,
                revivable: false))
        }

        // Ranked by when the agent moved, THEN cut. The old shape cut mid-walk
        // in mtime order, so WHICH sessions survived the cap was decided by the
        // contaminated clock too, not just where they sat. The cost is a tail
        // read for every interactive candidate in the window (~44 on this
        // machine) instead of the first `limit` — bounded by the window, and
        // the walk is cached (see ScanCache), so it is paid once per TTL.
        kept.sort { $0.lastActivityAt > $1.lastActivityAt }
        if kept.count > limit {
            result.beyondLimit = kept.count - limit
            kept.removeLast(kept.count - limit)
        }
        result.sessions = kept
        return result
    }

    /// When the agent last moved, read from inside the file rather than off it.
    ///
    /// The transcript's mtime does not mean this. Claude Code appends
    /// untimestamped bookkeeping (`bridge-session`, `atis-latch`, `last-prompt`,
    /// `ai-title`, `permission-mode`…) when a session is merely opened, resumed,
    /// or bridge-synced, and every such touch bumps the file's clock. Measured
    /// 19 Aug, the first restart this feature lived through: every dead
    /// transcript on the machine had been touched 1–7 hours after its last real
    /// entry, in the order Robert clicked through them afterwards — so the
    /// closed band ranked his BROWSE order and put a session idle since 08:38
    /// at the top. Same disease `SessionActivity.working(since:)` was cured of
    /// on 18 Aug ("the gate was never broken — it was being fed the wrong
    /// clock"); this is the ranking's dose of the same cure.
    ///
    /// The last entry carrying its own timestamp is the newest thing the
    /// conversation actually wrote; bookkeeping carries no timestamp at all, so
    /// under this reading it simply stops counting. Nil when nothing in the
    /// tail is dated — the caller falls back to mtime, which is then the only
    /// clock there is.
    static func lastMoved(tail lines: [String]) -> Date? {
        for line in lines.reversed() {
            guard let entry = json(line),
                  let at = SessionActivity.timestamp(of: entry) else { continue }
            return at
        }
        return nil
    }

    // MARK: - The classifiers, taking lines so every rule is testable

    /// POSITIVE evidence that a session was started by a machine rather than by
    /// a person: `sdk-cli` is `claude -p`, a cron job, our own replay harness.
    /// `cli` is a terminal someone is sitting at.
    ///
    /// Measured over 400 recent transcripts: every cron transcript is
    /// `sdk-cli`, and no cron transcript is `cli`. In a raw 7-day walk of this
    /// machine 460 of 504 transcripts are `sdk-cli` — which is what liveness
    /// used to filter out by ACCIDENT, since a headless run exits the instant
    /// it finishes and never appears in `claude agents --json`.
    ///
    /// The asymmetry is the whole design. Anything else — `cli`, a value a
    /// later Claude Code invents, a file we could not read — is treated as
    /// yours. Excluding on an absence is exactly the mistake the tty filter
    /// made when it "inferred 'nobody is here' from a proxy, and hid real
    /// conversations", and a stray robot row costs one glance where a hidden
    /// session costs the work.
    public static func isHeadless(_ entrypoint: String?) -> Bool { entrypoint == "sdk-cli" }

    /// The same question asked of a transcript on disk, for callers that hold a
    /// path rather than a parsed head — the announcer, in particular.
    ///
    /// Memoised without expiry, because a session's entrypoint is fixed the
    /// moment it starts: it cannot become interactive later. One 64KB read per
    /// session for the life of the process.
    public static func isHeadless(transcriptPath: String?) -> Bool {
        guard let transcriptPath else { return false }
        if let known = origins.get(transcriptPath) { return known }
        let verdict = isHeadless(classifiableHead(of: transcriptPath).flatMap { entrypoint(head: $0) })
        origins.put(transcriptPath, verdict)
        return verdict
    }

    private final class OriginCache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: Bool] = [:]
        func get(_ path: String) -> Bool? {
            lock.lock(); defer { lock.unlock() }; return known[path]
        }
        func put(_ path: String, _ headless: Bool) {
            lock.lock(); known[path] = headless; lock.unlock()
        }
    }
    private static let origins = OriginCache()

    static func entrypoint(head lines: [String]) -> String? {
        for line in lines {
            guard let entry = json(line) else { continue }
            if let value = entry["entrypoint"] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// The session's actual HOME — its most RECENT `cwd` if the tail shows
    /// one, falling back to the first `cwd` the head recorded.
    ///
    /// Was "the first cwd, full stop" until 23 Aug
    /// (2026-08-21-tb-division-of-labor's own finding): a session
    /// hand-started from `~`, then `cd`'d into a repo and stayed there for
    /// 540 turns plus 300 more in its worktree — still read
    /// `/Users/robertnowell` as home, because that came first. Unfindable
    /// by project name in Past Agents; `reviveCommand`, which reads this
    /// same value, would have resumed it in the wrong directory outright.
    ///
    /// The tail is checked FIRST, not the head — the caller already reads
    /// it (`SessionActivity.tail`, for `lastMoved`), so this costs no new
    /// I/O, and "where the conversation currently lives" is a strictly
    /// better answer to "where does a resume belong" than "where it
    /// started". Falls back to the head's first cwd, unchanged, whenever
    /// the tail has none — a very short session, or a caller (tests, most
    /// of them) that never had a tail to give it. The head's OWN
    /// first-entry logic is kept, not majority-voted, because it still
    /// correctly rejects the failure mode it was built for: a later entry
    /// carrying the directory the agent wandered into for one tool call — a
    /// skill's own folder, a subdirectory it read — is exactly as absent
    /// from a short head sample as it always was.
    ///
    /// Read rather than decoded. `-Users-robertnowell-Projects-kopi-promotions`
    /// cannot be turned back into a path without guessing, because a dash in
    /// the slug is either a separator or a dash in a directory name.
    static func firstCwd(head lines: [String], tail tailLines: [String] = []) -> String? {
        for line in tailLines.reversed() {
            guard let entry = json(line) else { continue }
            if let value = entry["cwd"] as? String, !value.isEmpty { return value }
        }
        for line in lines {
            guard let entry = json(line) else { continue }
            if let value = entry["cwd"] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Does a user PROMPT follow the final assistant message?
    ///
    /// The naive version of this is wrong in half of all cases, and quietly:
    /// a tool result is written as `"type":"user"`, so "is the last entry a
    /// user entry" answers yes for 241 of the 499 transcripts in a 7-day window
    /// — every one of them an agent mid-loop rather than a user who replied.
    ///
    /// Only two types are the conversation. Everything else — `last-prompt`,
    /// `attachment`, `system`, `ai-title`, `mode`, `bridge-session`, `pr-link`,
    /// whatever is added next — is bookkeeping and is skipped, the same shape
    /// `SessionActivity.classify` uses, so the two cannot drift apart.
    public static func isAnswered(tail lines: [String]) -> Bool {
        for line in lines.reversed() {
            guard let entry = json(line) else { continue }
            switch entry["type"] as? String {
            case "assistant":
                return false                            // the agent spoke last
            case "user":
                return isPrompt(entry)                  // you, or the loop feeding itself
            default:
                continue
            }
        }
        return true      // nothing conversational in the window: nothing is owed
    }

    /// A user entry that is genuinely you typing.
    ///
    /// Excluded: tool results (the loop), hook-injected meta entries (the
    /// harness talking to itself), and sidechain traffic (a subagent, not you).
    static func isPrompt(_ entry: [String: Any]) -> Bool {
        if entry["isMeta"] as? Bool == true { return false }
        if entry["isSidechain"] as? Bool == true { return false }
        guard let message = entry["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return false }
        return blocks.contains {
            ($0["type"] as? String) == "text"
                && !(($0["text"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Reading

    static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// The first `bytes`, split into whole lines. The last line of the window is
    /// dropped when the window was filled: a byte cap lands mid-record, and half
    /// a JSON object is not a record. Mirrors `SessionActivity.tail`, from the
    /// other end.
    static func head(of path: String, bytes: Int = headBytes) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes),
              let window = String(data: data, encoding: .utf8) else { return nil }
        var lines = window.split(separator: "\n").map(String.init)
        if data.count >= bytes, !lines.isEmpty { lines.removeLast() }
        return lines
    }

    /// The head, widened once if the first window held no `entrypoint`. See
    /// `headBytesEscalated` for the case that forced this.
    static func classifiableHead(of path: String) -> [String]? {
        guard let first = head(of: path) else { return nil }
        if entrypoint(head: first) != nil { return first }
        return head(of: path, bytes: headBytesEscalated) ?? first
    }

    static func isDirectory(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Where the projects home is, for the last resort below. Not a
    /// preference: a session with nowhere else to go still has a conversation
    /// worth reaching, and it has to open somewhere.
    static var projectsHome: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects").path
    }

    /// Where a revive should actually LAND, which is not always where the
    /// session ran.
    ///
    /// `revivable` used to ask "does the original directory still exist", and
    /// used that as a proxy for "will `--resume` work". The proxy is false, and
    /// measurably so: a session whose directory was deleted outright resumes
    /// from anywhere with its full conversation, the same session id, and no
    /// fork in the transcript — the cwd names the folder under
    /// `~/.claude/projects/` once, at birth, and the link is inert after that.
    /// Codex does not even do the naming; rollouts are filed by date and id.
    ///
    /// So the directory is not evidence about the session, only about where to
    /// stand. That matters because the proxy fails constantly rather than
    /// rarely: CLAUDE.md rule 5 requires closing a worktree when its work
    /// merges, and 60 of the 63 worktree sessions in a 60-day window on this
    /// machine were unrevivable for exactly that reason — 95%, caused by
    /// following the rule correctly.
    ///
    /// The ladder, ruled 24 Aug after two sessions were found stuck:
    ///
    /// 1. The original directory, when it still exists. Unchanged behaviour,
    ///    and the only rung that preserves the session's project config.
    /// 2. The git repository root above it. NOT "the nearest surviving
    ///    ancestor", which was the first proposal and would have shipped
    ///    broken: the nearest survivor of a deleted worktree is
    ///    `.claude/worktrees/`, a bookkeeping folder with no code in it. 56 of
    ///    69 real cases resolve here.
    /// 3. `~/Projects`, so a session with no repo above it is still reachable.
    ///    Refusing here protects nothing — the transcript exists either way —
    ///    and only removes the ability to talk to it.
    ///
    /// Never a temp directory. Every one of the 18 sessions found living under
    /// `/private/tmp` was a development artifact (TB's own `tb-goto-test` and
    /// `probe-proj` fixtures, whose first message is "say hello in one word",
    /// plus headless `claude -p` calls made by agents from inside their own
    /// scratchpads). Nothing real runs there, so nothing real is lost by
    /// refusing to reopen there — and reopening there would scatter an agent's
    /// work into a directory the OS reaps.
    ///
    /// Walks for a `.git` entry rather than shelling out to
    /// `rev-parse --show-toplevel`: this runs inside the scan that repaints the
    /// grid, and rule 9 keeps subprocess spawns off that path. Checks for
    /// EXISTENCE, not directory-ness, because a worktree's `.git` is a file.
    /// `temporaryRoots` and `home` are injected rather than read, for one
    /// reason: the tests build a REAL directory tree, because the ancestor walk
    /// is filesystem behaviour and a stubbed `fileExists` would pass while the
    /// walk was wrong. `NSTemporaryDirectory()` is itself under `/var/folders`,
    /// so a fixture has nowhere honest to live unless the guard can be pointed
    /// somewhere else. Production never passes either.
    public static func landingDirectory(for cwd: String?,
                                        _ fm: FileManager = .default,
                                        temporaryRoots: [String] = defaultTemporaryRoots,
                                        home: String? = nil) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        // Rung 1 answers before the guard, deliberately: the refusal below is
        // about REAPED paths, and a temp directory still standing was never
        // broken. Losing that would retire every live probe session.
        if isDirectory(cwd, fm) { return cwd }
        if isTemporary(cwd, temporaryRoots) { return nil }

        var dir = (cwd as NSString).standardizingPath
        while dir != "/" && !dir.isEmpty {
            if isDirectory(dir, fm) {
                if let root = repositoryRoot(from: dir, fm) { return root }
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        let fallback = home ?? projectsHome
        return isDirectory(fallback, fm) ? fallback : nil
    }

    /// The first ancestor of `dir` (inclusive) holding a `.git` entry.
    static func repositoryRoot(from dir: String, _ fm: FileManager) -> String? {
        var d = dir
        while d != "/" && !d.isEmpty {
            if fm.fileExists(atPath: (d as NSString).appendingPathComponent(".git")) {
                return d
            }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Paths the OS reaps. `/private/tmp` is the resolved form of `/tmp` on
    /// macOS and both are written in transcripts, so both are named here.
    public static let defaultTemporaryRoots =
        ["/private/tmp", "/tmp", "/private/var/folders", "/var/folders"]

    static func isTemporary(_ path: String,
                            _ roots: [String] = defaultTemporaryRoots) -> Bool {
        let p = (path as NSString).standardizingPath
        for root in roots where p == root || p.hasPrefix(root + "/") { return true }
        return false
    }

    // MARK: - Codex

    /// Codex's half of discovery — disk-only, like the walk above, but a
    /// separate function rather than a branch inside `scan`: `CodexRollout.
    /// parse` already gives structured data, so none of the raw-JSONL-line
    /// classifiers above (`entrypoint`, `firstCwd`, `isPrompt`, …) apply,
    /// and Codex's liveness story is deliberately different from Claude
    /// Code's — folding the two together would only tangle logic that
    /// doesn't share anything.
    ///
    /// Liveness is never guessed here — the settled design
    /// (2026-08-22-tb-codex-hand-started-adoption): Codex has no registry
    /// to ask, so every row reads `.unknown` uniformly rather than risk a
    /// wrong guess in either direction. `revivable` follows from that: true
    /// whenever the launch directory still exists, NOT gated on
    /// `liveness == .gone` the way Claude Code's is. Attempting a resume is
    /// always safe to try — `SessionLauncher.attemptCodexResume` reads
    /// Codex's own answer, live or not, rather than needing to know in
    /// advance. There is no `join(_:live:)` counterpart for this function:
    /// unlike Claude Code, there is nothing to join a process-table result
    /// onto — `.unknown` is deliberately the whole, final answer for every
    /// row, not a first half waiting for a second.
    ///
    /// The uncached full walk — `discoverCodexIfScanned` below is what the
    /// grid actually calls. Caching landed the same day this function did
    /// support a wired call site (22 Aug): CLAUDE.md rule 9 is explicit that
    /// an archive walk must never run inline on the main actor, and this one
    /// measured close to a second against 19 real rollouts on this machine
    /// — a number that only grows, the same shape `ScanCache` already exists
    /// to solve for Claude Code's own hundreds of transcripts.
    public static func discoverCodex(
        window: TimeInterval = defaultWindow,
        limit: Int = defaultLimit,
        now: Date = Date(),
        sessions: URL = CodexRollout.sessionsDirectory
    ) -> Result {
        var result = Result()
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: sessions, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return result }

        // One read for the whole walk. Codex keeps its own short summary per
        // thread (see `CodexThreadNames`), which is what makes a Codex row wear
        // a name instead of its directory.
        let names = CodexThreadNames.all()

        var kept: [Session] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) <= window else { continue }
            result.scanned += 1

            guard let text = try? String(contentsOfFile: url.path, encoding: .utf8)
            else { continue }
            let parsed = CodexRollout.parse(text)
            guard let sessionId = parsed.meta?.sessionId else {
                result.unclassifiable += 1
                continue
            }

            // No per-message timestamp exists in CodexRollout's parsed shape
            // yet — a real, known gap, not a design choice — so file mtime
            // is the only clock there is: the same fallback Claude Code's
            // own `lastMoved` uses when a tail holds nothing dated.
            let landable = landingDirectory(for: parsed.meta?.cwd, fm) != nil

            kept.append(Session(
                sessionId: sessionId,
                cwd: parsed.meta?.cwd,
                transcriptPath: url.path,
                title: names[sessionId.lowercased()],
                lastActivityAt: modified,
                answered: parsed.messages.last?.role == "user",
                activity: nil,       // no SessionActivity-equivalent classifier for Codex yet
                liveness: .unknown,
                revivable: landable,
                harness: CodexAdapter().id))
        }

        kept.sort { $0.lastActivityAt > $1.lastActivityAt }
        if kept.count > limit {
            result.beyondLimit = kept.count - limit
            kept.removeLast(kept.count - limit)
        }
        result.sessions = kept
        result.livenessUnavailable = true   // by design here, not a probe failure
        return result
    }

    /// A second `ScanCache` instance, not shared with Claude Code's own —
    /// the class itself is already generic (a TTL cache of `Result` keyed by
    /// a string; nothing in its body is Claude-Code-specific), so a second
    /// instance is the whole change, not a second implementation.
    private static let codexScans = ScanCache()

    /// The Codex twin of `discoverIfScanned`: non-blocking, returns nothing
    /// on a genuinely cold cache (the first tick after launch) rather than
    /// pay a synchronous walk on the caller's thread. No `join` step here,
    /// unlike Claude Code's — `discoverCodex` already IS the whole, final
    /// answer for every row (see its own doc comment on why liveness is
    /// never guessed), so there is nothing left to attach after the cache
    /// hit.
    public static func discoverCodexIfScanned(
        window: TimeInterval = defaultWindow,
        limit: Int = defaultLimit,
        now: Date = Date(),
        sessions: URL = CodexRollout.sessionsDirectory,
        ttl: TimeInterval = scanTTL
    ) -> Result? {
        let key = ScanCache.key(window, limit, sessions)
        let held = codexScans.get(key: key, now: now, ttl: ttl)
        if held == nil || held?.stale == true, codexScans.beginRefresh(key: key) {
            Task.detached(priority: .utility) {
                let fresh = discoverCodex(window: window, limit: limit, now: Date(),
                                          sessions: sessions)
                codexScans.put(key: key, now: Date(), result: fresh)
                codexScans.endRefresh(key: key)
            }
        }
        guard let held else { return nil }
        return held.result
    }

    /// Fill the Codex cache off-main at launch, the same reason `warm` does
    /// for Claude Code — without this the grid's Codex rows arrive a tick
    /// late instead of being there on the first paint.
    public static func warmCodex(
        window: TimeInterval = defaultWindow,
        limit: Int = defaultLimit,
        sessions: URL = CodexRollout.sessionsDirectory
    ) {
        let key = ScanCache.key(window, limit, sessions)
        guard codexScans.get(key: key, now: Date(), ttl: scanTTL) == nil,
              codexScans.beginRefresh(key: key) else { return }
        let result = discoverCodex(window: window, limit: limit, now: Date(), sessions: sessions)
        codexScans.put(key: key, now: Date(), result: result)
        codexScans.endRefresh(key: key)
    }

    /// The Codex twin of `settleForTesting` — waits for any background
    /// Codex scan to finish, same reason: a detached scan that outlives its
    /// test keeps doing disk I/O into whatever suite runs next.
    static func settleCodexForTesting(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while codexScans.isRefreshing, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
