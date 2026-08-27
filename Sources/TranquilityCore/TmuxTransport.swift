import Foundation

// MARK: - tmux subprocess runner

/// Every tmux invocation in the app goes through here, bounded. The pre-mortem
/// measured one send-keys call blocking 55 seconds against a pane in copy-mode
/// (once, not reproducibly) — which is exactly why no tmux call may run without
/// a deadline, the same discipline `AppleScript.run(timeout:)` earned against
/// busy Apple-events targets.
public enum Tmux {

    /// Wired by the host like every other Core trace.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// The socket TB-launched agents live on. A dedicated server, never the
    /// user's interactive one: kill-server blast radius, environment
    /// propagation, and name collisions all stop at this boundary (claude-squad
    /// and AWS's cli-agent-orchestrator both converged on the same isolation).
    public static let socketName = "tb"

    /// Where the dedicated server's socket lives. NOT /tmp: macOS's
    /// periodic-daily job deletes /tmp files unaccessed for 3+ days, which
    /// orphans a tmux server from its own socket (recoverable only by
    /// SIGUSR1). The user's default server keeps its default location —
    /// only OUR server moves.
    public static var socketDirectory: URL {
        QueueStore.supportDirectory.appendingPathComponent("tmux", isDirectory: true)
    }

    /// Locate the tmux binary without relying on PATH — a GUI-launched app
    /// inherits a minimal environment, the identical trap
    /// `ClaudeAgentsCLI.resolveBinary` exists for.
    /// Memoised: the login-shell fallback costs seconds, and an uncached
    /// miss on a tmux-less machine would pay it on every probe of every tick
    /// (M1 gate finding V10). A binary that appears later costs one relaunch,
    /// the same trade the claude binary's own resolution cache makes.
    private final class BinaryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false
        private var path: String?
        func get(or locate: () -> String?) -> String? {
            lock.lock(); defer { lock.unlock() }
            if !resolved { path = locate(); resolved = true }
            return path
        }
        func forget() {
            lock.lock(); defer { lock.unlock() }
            resolved = false; path = nil
        }
    }
    private static let binaryCache = BinaryCache()

    public static func resolveBinary() -> String? {
        binaryCache.get(or: locateBinary)
    }

    /// Drop the memo so the next `resolveBinary` looks again.
    ///
    /// The cache above deliberately remembers a MISS and states the trade: "a
    /// binary that appears later costs one relaunch." Fine while the only caller
    /// is the dispatch path; wrong the moment a first-run row tells someone to
    /// run `brew install tmux`, because the row would go green off its own
    /// uncached scan while dispatch kept refusing from the nil cached before the
    /// install. One machine, two answers, and the visible one wrong.
    ///
    /// Called only on that transition, so the login-shell fallback is not re-paid
    /// on every probe.
    public static func forgetBinary() { binaryCache.forget() }

    private static func locateBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        return Subprocess.loginShellWhich("tmux")
    }

    /// Run one tmux command, bounded. `socket` nil addresses the user's
    /// default server (their own TMUX_TMPDIR conventions, untouched);
    /// `Tmux.socketName` addresses our dedicated server in our own directory.
    /// `stdin` feeds the child (load-buffer reads the payload this way, so the
    /// text never crosses a shell or an argv boundary).
    @discardableResult
    public static func run(
        _ arguments: [String],
        socket: String? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 5
    ) -> Result<String, ScriptError> {
        guard let binary = resolveBinary() else {
            return .failure(ScriptError(message: "tmux binary not found"))
        }
        var env = ProcessInfo.processInfo.environment
        var argv = arguments
        if let socket {
            // Only the app's OWN server relocates out of /tmp (the periodic
            // cleanup trap). Any other named socket — a drill's throwaway
            // server — lives wherever tmux puts sockets by default, so the
            // shell that made it and the app code addressing it agree.
            if socket == socketName {
                try? FileManager.default.createDirectory(
                    at: socketDirectory, withIntermediateDirectories: true)
                env["TMUX_TMPDIR"] = socketDirectory.path
            }
            argv = ["-L", socket] + arguments
        } else {
            env.removeValue(forKey: "TMUX_TMPDIR")
        }
        // Never let a nested-TMUX guard misfire when the app itself was
        // launched from inside somebody's tmux.
        env.removeValue(forKey: "TMUX")
        return Subprocess.run(binary, argv, environment: env, stdin: stdin,
                              timeout: timeout)
    }

}

// MARK: - Ownership

/// Where a claude process actually lives, resolved from LIVE server inventory
/// and never from a stored string. The 19 Aug misfire is the reason this type
/// exists: two dead Terminal windows still claimed /dev/ttys011 after the tmux
/// server recycled that pty for a pane, the AppleScript walk matched the
/// corpse first, and a reply was typed into a window nothing would ever read.
/// A tty is an identity nowhere and an address nowhere; it is only the join
/// key between `ps` and what a live tmux server says it owns right now.
public struct TmuxPaneAddress: Sendable, Equatable {
    /// nil = the user's default server; `Tmux.socketName` = our dedicated one.
    public var socketName: String?
    /// The pane id ("%12") — the address every tmux call uses.
    public var paneId: String
    public var sessionName: String
    public var paneTty: String

    public init(socketName: String?, paneId: String, sessionName: String, paneTty: String) {
        self.socketName = socketName
        self.paneId = paneId
        self.sessionName = sessionName
        self.paneTty = paneTty
    }
}

public enum TmuxOwnership {

    /// The servers a pane may live on, checked in order: ours first (where
    /// TB-launched agents live), then the user's default server (where a
    /// hand-made agent like tb-probe lives).
    static var sockets: [String?] { [Tmux.socketName, nil] }

    /// The pane behind a pid, or nil when no live tmux server owns its tty.
    /// Resolved fresh at every call — the same "process facts go stale in
    /// seconds" rule the liveness join follows. A live server cannot serve a
    /// stale pane the way Terminal.app serves a dead tab, which is what makes
    /// this join safe where the AppleScript tty walk was not.
    public static func pane(forPid pid: Int) -> TmuxPaneAddress? {
        guard let tty = ProcessProbe.tty(of: pid) else { return nil }
        return pane(forTty: tty)
    }

    /// The pane a session is in, asked of the session's own registry entry
    /// before anything is inferred.
    ///
    /// The tty join below is three hops — pid to tty via `ps`, tty to pane via
    /// the server's inventory — and each hop can be stale or recycled while
    /// the session sits there perfectly alive. That is where "the session is
    /// right here and it couldn't open it" came from on 25 Aug: a pid twelve
    /// seconds out of date, and a button that answered "couldn't find a
    /// terminal for process 49931" about a pane one keystroke away.
    ///
    /// Claude Code writes the pane down itself. When it has, that is the
    /// answer; when it hasn't — a Codex session, a session too old to
    /// register — the join still runs, unchanged. A better source where one
    /// exists, never a second mechanism.
    ///
    /// The registry's pane id is still checked against the live server before
    /// it is returned: a registry file outlives the pane it names, and this
    /// type's whole contract (19 Aug) is that a pane address is resolved from
    /// LIVE inventory and never from a stored string.
    public static func pane(forSessionId sessionId: String, pid: Int?) -> TmuxPaneAddress? {
        if let entry = SessionRegistry.entry(forSessionId: sessionId),
           let paneId = entry.paneId,
           let address = paneById(paneId) {
            return address
        }
        guard let pid else { return nil }
        return pane(forPid: pid)
    }

    /// Confirm a pane id against live inventory, and fill in the rest of its
    /// address from what the server says rather than from the file.
    static func paneById(_ paneId: String) -> TmuxPaneAddress? {
        for socket in sockets {
            guard case .success(let out) = Tmux.run(
                ["list-panes", "-a", "-F", "#{pane_id}\t#{session_name}\t#{pane_tty}"],
                socket: socket, timeout: 3)
            else { continue }
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2,
                                       omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3, parts[0] == paneId else { continue }
                return TmuxPaneAddress(socketName: socket, paneId: parts[0],
                                       sessionName: parts[1], paneTty: parts[2])
            }
        }
        return nil
    }

    /// The same question asked with a tty already in hand — the launcher's
    /// trust watcher holds one before any process fact exists.
    public static func pane(forTty tty: String) -> TmuxPaneAddress? {
        if case .pane(let address) = ownership(forTty: tty) { return address }
        return nil
    }

    /// What the live servers say about a tty — including "they did not say".
    ///
    /// `pane(forTty:)` collapses three different answers into nil: the pane
    /// is there, the servers listed their panes and this tty is not among
    /// them, and the servers could not be asked. The first two are facts. The
    /// third is an absence of one, and it was being read as the second.
    ///
    /// That read has teeth. A session whose pane cannot be looked up is
    /// classified "hand-started", and a hand-started session is ENDED and
    /// resumed under tmux, on purpose, because a human and this app cannot
    /// both hold a bare terminal process. So a `list-panes` that times out —
    /// three seconds, on a machine with dozens of panes and a busy server —
    /// does not degrade to a missed jump. It kills a live agent.
    ///
    /// That is the unexplained half of the 26 Aug incident: a session that
    /// had been dispatching cleanly all day was SIGTERMed as if nobody had
    /// started it under tmux. The log recorded the conclusion ("is
    /// hand-started — transferring to tmux") and never the evidence, so
    /// after the fact there was no way to tell a real absence from a failed
    /// question. Both halves are fixed here: the answer distinguishes them,
    /// and the trace says which one it was.
    public enum Ownership: Equatable {
        /// A live server has this tty, at this address.
        case pane(TmuxPaneAddress)
        /// Every server answered, and none of them has it. A fact.
        case notInTmux
        /// At least one server could not be asked. NOT a fact, and never
        /// grounds for anything destructive.
        case unknown
    }

    /// Whether tmux said the server is not running, as opposed to failing to
    /// answer one that is.
    ///
    /// Read from tmux's own words rather than guessed from a socket path: the
    /// socket lives under `TMUX_TMPDIR`, which differs between this app and
    /// the shell a user runs tmux from, so any path this code reconstructs is
    /// a second source of truth that can disagree with the first. tmux says
    /// exactly one of two things when there is nothing to talk to, and both
    /// are definitive.
    static func serverIsAbsent(_ stderr: String) -> Bool {
        stderr.contains("no server running")
            || stderr.contains("No such file or directory")
    }

    public static func ownership(forTty tty: String) -> Ownership {
        var everyServerAnswered = true
        for socket in sockets {
            let listing = Tmux.run(
                ["list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{session_name}"],
                socket: socket, timeout: 3)
            guard case .success(let out) = listing else {
                guard case .failure(let error) = listing else { continue }
                // A server that is not running is not a server that failed to
                // answer. It holds no panes, definitively, and saying so is a
                // fact — the same fact an empty listing would be.
                //
                // Conflating the two, which this did for one hour on 26 Aug,
                // poisons every lookup on a machine that has no DEFAULT tmux
                // server: `sockets` asks ours and then the user's, the user's
                // does not exist, and the whole answer collapses to `.unknown`
                // even though our own server answered perfectly. GO TO AGENT
                // then ended live sessions and reported "the resumed pane is
                // not on any live tmux server" about a pane sitting on the
                // server it had just been created on. My regression, found by
                // the trace added in the same change — which is the only
                // reason it took minutes instead of an evening.
                if !Self.serverIsAbsent(error.message) {
                    everyServerAnswered = false
                    Tmux.trace?("ownership: \(socket ?? "default") server did not answer "
                        + "for \(tty)")
                }
                continue
            }
            if let address = match(inventory: out, tty: tty, socket: socket) {
                return .pane(address)
            }
        }
        if !everyServerAnswered {
            Tmux.trace?("ownership: \(tty) UNKNOWN — a server could not be asked, so this is "
                + "not evidence the session is hand-started")
            return .unknown
        }
        return .notInTmux
    }

    /// Pure half, testable without a server.
    static func match(inventory: String, tty: String, socket: String?) -> TmuxPaneAddress? {
        for line in inventory.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2,
                                   omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0] == tty else { continue }
            return TmuxPaneAddress(socketName: socket, paneId: parts[1],
                                   sessionName: parts[2], paneTty: parts[0])
        }
        return nil
    }
}

extension Array where Element == LiveSession {
    /// Which of possibly-several rows sharing a sessionId to dispatch into,
    /// the first time a target is chosen — before any pid is known, unlike
    /// `matching(sessionId:pid:)` in DispatchTransport.swift, which a
    /// transport uses once Coordinator has already decided. Preferring the
    /// tmux-owned pid means a reply lands in TB's own pane when a session is
    /// dual-live (resumed by TB alongside a foreground process the user
    /// never asked TB to touch — Claude Code tolerates this, and even
    /// arbitrates it with its own "Remote Control" feature) rather than an
    /// arbitrary one of the rows `agents --json` happens to list first.
    ///
    /// Scoped to the tmux-owned half of the ambiguity, honestly: ruled 21 Aug,
    /// every NEW launch is tmux, no flag, no opt-in — but a hand-started
    /// session (Claude Code, opened by the user in their own plain Terminal
    /// tab, never launched by TB at all) is a real, load-bearing shape
    /// (`docs/log/architecture-program.md`'s adoption ruling: every session is
    /// adoptable, wherever it started). Two such rows for one sessionId, or
    /// one of TB's own resumed into a Terminal.app window while a Terminal.app
    /// row already exists, still resolves arbitrarily here — that is not a
    /// regression (Terminal.app dispatch carried the same ambiguity before
    /// this fix), and closing it fully needs either the adoption/handoff
    /// state machine (which never leaves TWO Terminal.app rows for the
    /// SAME conversation live at once by construction) or a live
    /// Terminal.app-tab discriminator analogous to `TmuxOwnership` — the arc
    /// is not building the latter, since the plan deletes Terminal.app
    /// dispatch entirely once Codex is proven (single-transport cut). More
    /// than one tmux-owned row for one sessionId is the genuine anomaly (two
    /// tmux panes cannot share a pid's tty) and is traced identically.
    ///
    /// Returns the pane resolved while deciding, when deciding required
    /// resolving one at all — the common single-row case never queries a live
    /// tmux server, so `pane` is nil there and the caller resolves fresh
    /// exactly as before. When there WAS more than one row, the caller must
    /// reuse this pane rather than re-querying: two live `pane(forPid:)` calls
    /// milliseconds apart for the same fact can disagree if a pane closes in
    /// between, and a row chosen BECAUSE it was tmux-owned dispatched moments
    /// later as `.terminalApp` is the 19 Aug misfire's shape exactly.
    ///
    /// `resolvePane` defaults to the live check but is injectable: it is the
    /// only thing standing between this decision and a live tmux server, and
    /// a fake makes the decision itself testable without one.
    public func preferringTmuxOwned(
        sessionId: String,
        resolvePane: (Int) -> TmuxPaneAddress? = { TmuxOwnership.pane(forPid: $0) },
        trace: (@Sendable (String) -> Void)? = nil
    ) -> (session: LiveSession, pane: TmuxPaneAddress?)? {
        let matches = filter { $0.sessionId == sessionId }
        guard let firstMatch = matches.first else { return nil }
        guard matches.count > 1 else { return (firstMatch, nil) }
        let tmuxOwned = matches.compactMap { row -> (LiveSession, TmuxPaneAddress)? in
            resolvePane(row.pid).map { (row, $0) }
        }
        if tmuxOwned.count == 1 { return tmuxOwned[0] }
        trace?("dispatch: \(sessionId.prefix(8)) has \(matches.count) duplicate rows, "
            + "\(tmuxOwned.count) tmux-owned; picking the first, arbitrarily")
        // The fallback still owes its OWN doc's reuse promise: if the row it is
        // about to return happens to be one of the tmux-owned ones (the only
        // way this branch is reached with count > 1 — two tmux panes on one
        // pid's tty), returning its already-resolved pane here is what stops
        // the caller re-querying and risking the two live lookups disagreeing.
        // Found by the codebase audit, 21 Aug: this used to discard it.
        if let reuse = tmuxOwned.first(where: { $0.0.pid == firstMatch.pid }) {
            return reuse
        }
        return (firstMatch, nil)
    }
}

// MARK: - Transport

/// The closed-loop tmux transport. Validated before it was written: 100/100
/// exact-once deliveries under adversarial copy-mode churn and 3/3 against a
/// live Claude Code session, one launched with the pane already in copy-mode
/// (2026-08-19-tb-delivery-protocol-proof). The shape of the guarantee: no
/// timer ever decides an outcome — every wait polls an observable
/// postcondition, every retry is guarded by dedupe against the transcript, so
/// a message can be retried forever without ever landing twice.
/// One dispatch at a time per pane, across PROCESSES.
///
/// A composer is a single shared mutable thing, and two sends into it
/// interleave exactly as badly as that sounds: the second reads the floor
/// while the first is mid-paste, joins onto a half-written message, or clears
/// it. Measured 26 Aug by the live drill — two `tbase send` calls with no gap,
/// and one of the two messages was never delivered at all.
///
/// A file lock rather than an in-process one, because the second writer is
/// usually a different process. `tbase` is a real dispatch door, not a lesser
/// one (CLAUDE.md rule 7), and crons and a second panel are the same shape; an
/// actor would serialise the app against itself and miss every case that
/// actually happens. `DeliveryInFlight` does not cover this and never meant
/// to: it is a lamp overlay describing what the panel is doing, not a mutex
/// over a terminal.
///
/// Bounded, and it fails OPEN. A stuck holder must not silently stop delivery
/// forever; after the ceiling this proceeds unlocked and says so, which is a
/// risk of interleaving in a case that was 100% interleaved before this
/// existed.
enum PaneDispatchLock {

    /// Long enough for a real dispatch (a confirmed one is ~1s, a failing one
    /// runs its full verification window), short enough that a crashed holder
    /// costs one delivery's latency rather than the delivery.
    static let ceiling: TimeInterval = 45

    /// Returns the held descriptor, or nil when it gave up waiting.
    static func acquire(paneId: String, trace: ((String) -> Void)? = nil) -> Int32? {
        let dir = Tmux.socketDirectory.deletingLastPathComponent()
            .appendingPathComponent("locks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Pane ids are "%12"; the percent is not a filename problem but the
        // sanitising is free and the intent is clearer than trusting it.
        let name = paneId.replacingOccurrences(of: "%", with: "pane-")
        let fd = open(dir.appendingPathComponent("\(name).lock").path,
                      O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(ceiling)
        while Date() < deadline {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            Thread.sleep(forTimeInterval: 0.05)
        }
        trace?("dispatch: pane \(paneId) lock not acquired in \(Int(ceiling))s — "
            + "proceeding unlocked rather than dropping the message")
        close(fd)
        return nil
    }

    static func release(_ fd: Int32?) {
        guard let fd else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }
}

public struct TmuxTransport: DispatchTransport {

    /// One line per dispatch attempt, wired by the host like every other
    /// Core trace. There was no record of what the composer held or what was
    /// done about it, so "my link did not send" could only be answered by
    /// reading a screenshot — and a transport nobody can audit is not
    /// trustworthy however correct it is.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    public let kind: TransportKind = .tmux
    public var verificationTimeout: TimeInterval
    public var pollInterval: TimeInterval
    private let agents: ClaudeAgentsReading

    public init(
        verificationTimeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.1,
        agents: ClaudeAgentsReading = ClaudeAgentsCLI()
    ) {
        self.verificationTimeout = verificationTimeout
        self.pollInterval = pollInterval
        self.agents = agents
    }

    public func readiness(for target: DispatchTarget) async -> Readiness {
        guard let pid = target.pid, ProcessProbe.isAlive(pid) else { return .targetGone }
        guard let pane = target.pane, paneExists(pane) else { return .targetGone }

        switch target.readinessSource {
        case .processAlive:
            return .ready
        case .claudeAgents:
            // The same gate as every transport, from the one shared mapping.
            return Readiness.classify((agents.sessions() ?? [])
                .matching(sessionId: target.sessionId, pid: pid))
        case .rolloutTail:
            // See `Readiness.classify(rollout:sessionId:liveThreadIds:)`'s
            // own doc comment for why a nil rollout alone is not enough to
            // refuse — this disambiguates "no turns yet" from "not found".
            return Readiness.classify(
                rollout: CodexRollout.parse(sessionId: target.sessionId),
                sessionId: target.sessionId,
                liveThreadIds: CodexRollout.liveThreadIds())
        }
    }

    /// The V4 re-probe (gate finding, PR #163): a session can pop a modal
    /// between an Enter that landed nothing and the retry that would submit
    /// it, and a Return at a dialog ANSWERS it. Shared by both places `send`
    /// presses a bare Enter with no fresh text underneath it — codebase audit
    /// (21 Aug) found the second one had been built without this call.
    ///
    /// Scoped to `.claudeAgents` on purpose, not every `readinessSource`:
    /// `Readiness.classify(rollout:)` never produces `.waiting`, so a Codex
    /// target reads `isDialog == false` here unconditionally. That is an
    /// honest "unverified", not a measured "safe" — nothing has confirmed
    /// whether Codex can pop an equivalent modal in this exact window.
    private func dialogIsUp(target: DispatchTarget, pid: Int) -> Bool {
        target.readinessSource == .claudeAgents
            && Readiness.classify((agents.sessions() ?? [])
                .matching(sessionId: target.sessionId, pid: pid)).isDialog
    }

    /// Deliver `text` into a live TUI composer and prove it arrived.
    ///
    /// ONE PASTE PER SEND. That is the whole design, and it is a structural
    /// property rather than a rule this function tries to follow: the paste
    /// happens on exactly one code path, guarded by `pasted`, and no
    /// observation of any kind can send control back to it. Everything that
    /// used to decide "paste again" now decides at most "press Return again",
    /// which is idempotent on an empty composer and therefore free.
    ///
    /// Rewritten 26 Aug after eight repairs in eight days, all of them the
    /// same shape: the transport read a terminal's screen, got it wrong
    /// because the terminal had changed how it draws, and the penalty for
    /// getting it wrong was a second paste. Five glued copies of somebody's
    /// sentence, unsent, twice in one morning. Accuracy of a screen scrape
    /// was load-bearing for correctness, which is not a property that can be
    /// made reliable by reading the screen more carefully — only by making
    /// the reading non-critical.
    ///
    /// So the screen now has exactly one job, done once, before anything is
    /// typed: protect text a human already put in the box. Nothing else can
    /// see that, which is why it cannot be dropped. DELIVERY, by contrast, is
    /// proved from the transcript — the harness's own first-hand record that
    /// it took the message, `user` line or `queue-operation` enqueue — and
    /// the transcript cannot be wrong about that in the way a repaint can.
    ///
    /// The second attempt exists, and it is gated on PROOF that the first
    /// delivered nothing: a silent transcript AND an empty composer. Absence
    /// of confirmation is not that proof; a composer holding our words is the
    /// opposite of it. Anything else reports failure with the words left
    /// exactly where they are, which is a state a person can see and act on.
    public func send(text: String, to target: DispatchTarget) async -> DispatchOutcome {
        guard let pane = target.pane else {
            return .failed(.injectionFailed("tmux target has no pane address"))
        }
        // Local on purpose: the dialog re-check needs this pid, and today it
        // only runs because `readiness(for:)` fails closed on a nil one.
        guard let pid = target.pid else { return .failed(.targetGone) }
        let state = await readiness(for: target)
        let wasBusy = state == .busy
        guard state.canDispatch else {
            return state == .targetGone ? .failed(.targetGone) : .deferred(state)
        }

        let payload = DispatchText.flatten(text)
        guard !payload.isEmpty else { return .failed(.injectionFailed("empty text")) }

        // Serialised per pane from here to the end, across processes. Taken
        // AFTER the cheap refusals so a malformed send never queues behind a
        // real one.
        let lock = PaneDispatchLock.acquire(paneId: pane.paneId, trace: Self.trace)
        defer { PaneDispatchLock.release(lock) }

        let start = Date()
        // Everything appended before this instant is history, and history is
        // not evidence about this delivery. Without it a short reply ("yes")
        // that ever appeared in an earlier message false-confirms without
        // sending — found by the 19 Aug audit hours after this shipped.
        let watermark = TranscriptWatcher.fileSize(atPath: target.transcriptPath
            ?? TranscriptArchive.transcriptPath(forSessionId: target.sessionId))
        func elapsed() -> Int { Int(Date().timeIntervalSince(start) * 1000) }

        // Set once any attempt has seen its own words in the composer.
        var accepted = false

        for attempt in 0..<2 {
            if attempt == 1 {
                // The retry gate. Both conditions, and both are positive
                // evidence rather than the absence of good news: the
                // transcript has nothing of ours, and the composer is empty,
                // so the first attempt provably delivered nothing anywhere.
                if alreadyDelivered(payload, target: target, fromByteOffset: watermark) {
                    return .confirmed(latencyMs: elapsed())
                }
                guard composerIsEmpty(pane, target: target) else { break }
            }

            guard paneExists(pane) else { return .failed(.targetGone) }
            // Text sent into copy-mode is destroyed outright — not queued, not
            // shown. Cleared and VERIFIED cleared before anything is typed.
            if !clearMode(pane) {
                return .failed(.injectionFailed("pane stuck in copy-mode"))
            }
            if alreadyDelivered(payload, target: target, fromByteOffset: watermark) {
                return .confirmed(latencyMs: elapsed())
            }

            // ── The one screen read. Its only question is what a human left
            // in the box, and its only power is to preserve it.
            var expectedInBox = payload
            var pasted = false
            // Whether we SAW our words in the box. Advisory for the paste (a
            // slow repaint must never cause a second one), but decisive at the
            // end: our text seen in the box, and the box empty after Return,
            // is first-hand evidence the TUI took the message — evidence that
            // does not depend on a file being written in time.
            var echoSeen = false
            let floor = Self.decide(line: promptLine(
                pane, payload: payload, glyph: target.promptGlyph,
                placeholder: target.idlePlaceholder, chip: target.pasteChip,
                ourChips: []))

            var joining = false
            // One line per attempt, said out loud. There was no record of
            // what the box held or what was done about it, so "my link did
            // not send" could only be answered by forensics on a screenshot
            // — and a transport nobody can audit cannot be trusted, however
            // correct it is. Cheap: one line per send, not per poll.
            Self.trace?("dispatch: \(target.sessionId.prefix(8)) attempt \(attempt) "
                + "floor=\(floor) payload=\(payload.count)b")
            switch floor {
            case .returnOnly:
                // Our own words are already sitting there unsubmitted, from a
                // send that ended without them going in. Pasting would make
                // two of them; Return makes one message.
                break
            case .joinExisting:
                // Keep what is there and put ours after it, so the two things
                // the user meant as one message arrive as one message. Read
                // first: this is the only moment they are still separable.
                if let rows = Self.boxRows(screen: screen(pane) ?? "",
                                           glyph: target.promptGlyph) {
                    let before = Self.collapsed(rows.joined(separator: " "))
                    if !before.isEmpty { expectedInBox = before + " " + payload }
                }
                Tmux.run(["send-keys", "-t", pane.paneId, "C-e"], socket: pane.socketName)
                joining = true
            case .paste:
                break
            }

            if floor != .returnOnly {
                // load-buffer over stdin: no shell, no argv, no per-key
                // interpretation, byte-exact (measured at 1,587 chars with
                // quotes and dollar signs intact). The ONLY paste in this
                // function, and `pasted` is what says so afterwards.
                guard case .success = Tmux.run(
                    ["load-buffer", "-b", "tb-dispatch", "-"],
                    socket: pane.socketName,
                    stdin: Data((joining ? "\n" + payload : payload).utf8))
                else { continue }
                Tmux.run(["paste-buffer", "-b", "tb-dispatch", "-d", "-p", "-t", pane.paneId],
                         socket: pane.socketName)
                pasted = true

                // Advisory, never a gate. A TUI takes a moment to draw a
                // paste, and pressing Return into a half-ingested one is the
                // race this waits out. It used to decide whether to paste
                // AGAIN, which is what made a slow repaint into a duplicate;
                // now a timeout here just means "press Return anyway", and
                // Return on a composer that never received the paste does
                // nothing at all.
                echoSeen = poll(deadline: 6.0, every: 0.05, until: {
                    guard let text = screen(pane) else { return false }
                    return text.contains(payload)
                        || Self.boxHolds(payload: expectedInBox, screen: text,
                                         glyph: target.promptGlyph)
                        || !Self.pasteChips(screen: text, glyph: target.promptGlyph,
                                            chip: target.pasteChip).isEmpty
                })
            }
            // `.returnOnly` means the box already held our words when this
            // send started, which is the same evidence a fresh echo gives.
            if floor == .returnOnly { echoSeen = true }
            _ = pasted
            accepted = accepted || echoSeen

            // ── Submit and prove it. Return is idempotent; the transcript is
            // the witness. A dialog re-check before every one of them, because
            // a Return at a modal ANSWERS it (gate finding V4) and a session
            // can raise one between two of these.
            for round in 0..<3 {
                if dialogIsUp(target: target, pid: pid) { break }
                // Copy-mode before EVERY Return, not just once at the top of
                // the send. Return is a copy-mode key — in copy-mode it moves
                // the selection instead of submitting, so a pane that entered
                // copy-mode between the paste and the Return silently eats the
                // submit and leaves the words sitting in the box.
                //
                // Traced 26 Aug rather than guessed: every remaining failure
                // under the churn drill was `boxEmpty=false` at the end, on a
                // send whose text was still in the composer. It read as a
                // false alarm only because the NEXT send joined onto the
                // stranded text and submitted both, so the message arrived
                // late and under someone else's send. Clearing here is the
                // difference between an Enter that submits and one that
                // scrolls.
                _ = clearMode(pane)
                Tmux.run(["send-keys", "-t", pane.paneId, "Enter"], socket: pane.socketName)
                let window: TimeInterval = round == 2 ? verificationTimeout : 4
                if await landedInTranscript(payload, target: target, timeout: window,
                                            fromByteOffset: watermark) {
                    Self.trace?("dispatch: \(target.sessionId.prefix(8)) confirmed after "
                        + "\(round + 1) return(s), \(elapsed())ms")
                    return .confirmed(latencyMs: elapsed())
                }
            }
        }
        Self.trace?("dispatch: \(target.sessionId.prefix(8)) NOT confirmed — "
            + "boxEmpty=\(composerIsEmpty(pane, target: target)) wasBusy=\(wasBusy)")

        // One last look before calling it a failure.
        //
        // Every check above is bounded, and a bounded check that ran out of
        // time is not evidence the message never arrived — under load the
        // transcript write can simply be slower than the last poll. Measured
        // 26 Aug by the copy-mode churn drill: ten messages, ten landed, and
        // one send reported an error anyway. Nothing was lost; the report was
        // wrong, which is its own kind of unreliable — it is the shape of
        // every "it said it failed but it went" this app has produced.
        //
        // One file read, on a path that has already spent its whole budget,
        // and it can only ever turn a false failure into a true confirmation.
        // A glance, not a wait. A three-second poll was tried here and
        // measured WORSE — 3 failures in 6 drill runs against 1 in 6 for the
        // glance — because the extra seconds sit inside every failing send and
        // hand the next one a busier pane. Tuning a timeout against a
        // stochastic drill is how this file grew its knobs; this one is a free
        // file read on a path that has already given up.
        if alreadyDelivered(payload, target: target, fromByteOffset: watermark) {
            Self.trace?("dispatch: \(target.sessionId.prefix(8)) confirmed on the final "
                + "check — the verification window expired before the transcript caught up")
            return .confirmed(latencyMs: elapsed())
        }

        // ── ACCEPTED, not failed.
        //
        // Our words went into the box, we watched them arrive, we pressed
        // Return, and the box is now empty. The TUI took them. That is
        // first-hand evidence of acceptance and it does not depend on a file
        // being written before a deadline — which is the one thing every
        // remaining false alarm has in common.
        //
        // Measured 26 Aug: under adversarial copy-mode churn, one send in
        // sixty reported failure while all sixty messages had arrived exactly
        // once. Every one of those was this state — accepted, transcript
        // lagging — and calling it a failure sends someone to check a tab
        // where their message is already sitting.
        //
        // BOTH halves are required, and neither alone would do. An empty box
        // on its own is also what a paste that never landed looks like; an
        // echo on its own says nothing about whether Return was taken. It is
        // the transition between them that means "taken".
        //
        // `.queued` rather than `.confirmed`, because the difference is real
        // and the receipt says so: the words are in the session, not yet in
        // its transcript. That is exactly what a message typed into a busy
        // session looks like, which is why the outcome already exists.
        if accepted && composerIsEmpty(pane, target: target) {
            Self.trace?("dispatch: \(target.sessionId.prefix(8)) accepted — echoed, "
                + "submitted, box now empty; transcript has not caught up")
            return .queued
        }

        // A busy session may hold the words in its own queue for a while; the
        // enqueue record is read now, so this is genuinely the last resort
        // rather than the ordinary busy path it used to be.
        if wasBusy { return .queued }
        return .failed(.verificationTimedOut)
    }

    /// Nothing in the composer — the second half of the retry gate.
    /// Deliberately conservative: an unreadable box is NOT empty, because
    /// "we could not see" must never authorise a second paste.
    private func composerIsEmpty(_ pane: TmuxPaneAddress, target: DispatchTarget) -> Bool {
        // Copy-mode first, always. A pane in copy-mode shows SCROLLBACK, so
        // `capture-pane` returns a historical view and the "last prompt line"
        // is some earlier prompt with an earlier message after it — a box that
        // is empty reads as full, and one that is full can read as empty.
        //
        // Found 26 Aug by tracing the drill instead of guessing at it: the
        // adversary shoves the pane into copy-mode at random, and every
        // remaining false alarm traced to `boxEmpty=false` on a session whose
        // message had already landed. It was never a timing problem; the
        // reader was looking at the wrong screen.
        //
        // Clearing is safe here and everywhere else this file does it: leaving
        // a pane in copy-mode is itself the condition that destroys injected
        // text, which is why step 2 of every send clears it too.
        _ = clearMode(pane)
        guard let text = screen(pane),
              let rows = Self.boxRows(screen: text, glyph: target.promptGlyph)
        else { return false }
        let content = Self.collapsed(rows.joined(separator: " "))
        if content.isEmpty { return true }
        if let placeholder = target.idlePlaceholder, content == placeholder { return true }
        return false
    }

    // MARK: observations (each one a postcondition something above polls)

    private func paneExists(_ pane: TmuxPaneAddress) -> Bool {
        if case .success = Tmux.run(["list-panes", "-t", pane.paneId, "-F", "ok"],
                                    socket: pane.socketName, timeout: 3) { return true }
        return false
    }

    private func inMode(_ pane: TmuxPaneAddress) -> Bool {
        guard case .success(let out) = Tmux.run(
            ["display-message", "-p", "-t", pane.paneId, "#{pane_in_mode}"],
            socket: pane.socketName, timeout: 3) else { return false }
        return out == "1"
    }

    private func clearMode(_ pane: TmuxPaneAddress) -> Bool {
        for _ in 0..<10 {
            guard inMode(pane) else { return true }
            Tmux.run(["send-keys", "-t", pane.paneId, "-X", "cancel"],
                     socket: pane.socketName, timeout: 3)
            if poll(deadline: 0.5, every: 0.05, until: { !inMode(pane) }) { return true }
        }
        return !inMode(pane)
    }

    /// Empty the composer, however many rows it is holding, and stop as soon
    /// as it is empty rather than after a fixed number of keys. Bounded: an
    /// unreadable box gets the same handful of attempts and no more.
    static func clearBox(pane: TmuxPaneAddress, glyph: String,
                         screen: () -> String?) {
        for _ in 0..<12 {
            let rows = boxRows(screen: screen() ?? "", glyph: glyph) ?? []
            let text = collapsed(rows.joined(separator: " "))
            if text.isEmpty { return }
            Tmux.run(["send-keys", "-t", pane.paneId, "C-a"], socket: pane.socketName)
            Tmux.run(["send-keys", "-t", pane.paneId, "C-k"], socket: pane.socketName)
        }
    }

    private func screen(_ pane: TmuxPaneAddress) -> String? {
        guard case .success(let out) = Tmux.run(
            ["capture-pane", "-p", "-J", "-t", pane.paneId],
            socket: pane.socketName, timeout: 3) else { return nil }
        return out
    }

    private func screenContains(_ payload: String, _ pane: TmuxPaneAddress) -> Bool {
        screen(pane)?.contains(payload) ?? false
    }

    /// What the input box shows about the paste step 4 just made.
    enum PasteEcho: Equatable {
        case absent
        /// The payload itself is readable in the box — the short-message
        /// case, and the only case the transport used to be able to see.
        case literal
        /// The TUI collapsed it and drew this chip instead.
        case chip(String)
    }

    private func pasteEcho(_ payload: String, _ pane: TmuxPaneAddress,
                           target: DispatchTarget, chipsBefore: Set<String>,
                           expectedInBox: String) -> PasteEcho {
        guard let text = screen(pane) else { return .absent }
        if text.contains(payload)
            || Self.boxHolds(payload: expectedInBox, screen: text, glyph: target.promptGlyph) {
            return .literal
        }
        // Sorted so the choice is deterministic if a paste ever draws two
        // chips; in practice `fresh` holds exactly one.
        let fresh = Self.pasteChips(screen: text, glyph: target.promptGlyph,
                                    chip: target.pasteChip).subtracting(chipsBefore)
        if let one = fresh.sorted().first { return .chip(one) }
        return .absent
    }

    /// Still ours, still unsubmitted — asked AFTER a Return, where a FRESH
    /// chip is the wrong question (the box either cleared or it did not)
    /// and identity is the right one: is what sits there still the thing
    /// this send put there.
    private func stillHolding(_ payload: String, _ pane: TmuxPaneAddress,
                              target: DispatchTarget, ourChips: Set<String>,
                              expectedInBox: String) -> Bool {
        guard let text = screen(pane) else { return false }
        if text.contains(payload)
            || Self.boxHolds(payload: expectedInBox, screen: text, glyph: target.promptGlyph) {
            return true
        }
        return !Self.pasteChips(screen: text, glyph: target.promptGlyph,
                                chip: target.pasteChip).isDisjoint(with: ourChips)
    }

    /// The input box's rendered rows, glyph row first.
    ///
    /// A TUI does not let the terminal wrap its composer; it draws each row
    /// itself, indented under the glyph, which is why `capture-pane -J`
    /// never joins them and why a payload wider than the pane is on screen
    /// and yet absent from any `contains` test (measured 23 Aug: a
    /// 2,444-char payload, fully visible, `screen.contains(payload) ==
    /// false` with and without `-J`). Reading the box as rows is what makes
    /// "is our text in the box" answerable rather than merely usually true.
    static func boxRows(screen: String, glyph: String) -> [String]? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(glyph)
        }) else { return nil }
        var rows = [String(lines[start].trimmingCharacters(in: .whitespaces)
            .dropFirst(glyph.count).trimmingCharacters(in: .whitespaces))]
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The box ends at its own border rule; a continuation row is
            // always indented under the glyph and never empty.
            guard line.hasPrefix("  "), !trimmed.isEmpty, !trimmed.hasPrefix("─") else { break }
            rows.append(trimmed)
        }
        return rows
    }

    /// Does the box hold exactly our payload, however many rows it took?
    ///
    /// EQUALITY, not containment, over whitespace-collapsed text: the row
    /// breaks the TUI inserts are not in the payload, and a substring test
    /// here would accept a box holding our words PLUS somebody else's —
    /// which is the splice `.holds(ours: false)` exists to refuse.
    static func boxHolds(payload: String, screen: String, glyph: String) -> Bool {
        guard let rows = boxRows(screen: screen, glyph: glyph) else { return false }
        return collapsed(rows.joined(separator: " ")) == collapsed(payload)
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Every paste chip currently drawn in the box, WHOLE — `chip` is only
    /// the stable prefix, since the identifying part (Claude Code's
    /// counter, Codex's byte count) is what makes one chip distinguishable
    /// from the next, and telling them apart is the entire point.
    static func pasteChips(screen: String, glyph: String, chip: String?) -> Set<String> {
        guard let chip, !chip.isEmpty, let rows = boxRows(screen: screen, glyph: glyph)
        else { return [] }
        var found: Set<String> = []
        for row in rows {
            var rest = Substring(row)
            while let open = rest.range(of: chip) {
                guard let close = rest[open.upperBound...].firstIndex(of: "]") else { break }
                found.insert(String(rest[open.lowerBound...close]))
                rest = rest[rest.index(after: close)...]
            }
        }
        return found
    }

    enum PromptLine: Equatable {
        case empty
        case holds(ours: Bool)
        case unreadable
    }

    /// What a send does with the input line, decided once, before anything
    /// is typed. Three outcomes, because there are only three things that can
    /// be in the box: nothing, our own unsent words, or a person's.
    enum FloorAction: Equatable {
        /// An empty box. Paste.
        case paste
        /// Our own words, already there and never submitted — from a send
        /// that ended without its Return landing. Return, never paste: a
        /// paste here is how you get two of the same message.
        case returnOnly
        /// Somebody typed something. Keep it and put ours after it, so the
        /// two things they meant as one message arrive as one message.
        case joinExisting
    }

    /// The floor decision, from the box alone.
    ///
    /// It used to take `everEchoed` and `firstAttempt`, because the caller
    /// could paste more than once per send and this had to keep answering
    /// "is a second paste safe now". A send pastes once, so the question is
    /// gone and so are the parameters — and with them `.stop`, which only
    /// ever meant "you have already pasted", and `.clearThenPaste`, which
    /// existed only to make room for pasting again. Deleting a person's
    /// typing was never a goal; it was the cost of a retry that no longer
    /// happens.
    ///
    /// `.unreadable` pastes. With no second paste to fear, the cost of being
    /// wrong here is a splice into text we could not see — which is what
    /// joining does on purpose anyway — while the cost of refusing would be
    /// a message silently not delivered.
    static func decide(line: PromptLine) -> FloorAction {
        switch line {
        case .empty, .unreadable: return .paste
        case .holds(ours: true): return .returnOnly
        case .holds(ours: false): return .joinExisting
        }
    }


    /// What sits on the input line right now. Each harness's TUI draws its
    /// input box prefixed with its own glyph — Claude Code's `❯`, Codex's
    /// `›` — read from `target.promptGlyph` (`DispatchTransport.swift`),
    /// never hardcoded here; this is what makes the floor check (never
    /// splice into someone's unsent text) mean something on more than one
    /// harness. A plain-shell target (the test harness) has no glyph match
    /// and reads as empty, which is right — its "input line" is wherever the
    /// cursor is, and the landing check in step 5 is the guard that matters
    /// there.
    private func promptLine(
        _ pane: TmuxPaneAddress, payload: String, glyph: String, placeholder: String?,
        chip: String?, ourChips: Set<String>
    ) -> PromptLine {
        guard let text = screen(pane) else { return .unreadable }
        return Self.classifyPromptLine(screen: text, payload: payload, glyph: glyph,
                                       placeholder: placeholder, chip: chip,
                                       ourChips: ourChips)
    }

    /// Pure half, testable against captured screens. `glyph` defaults to
    /// Claude Code's own so every existing call site (and every existing
    /// test) keeps meaning exactly what it always has.
    static func classifyPromptLine(
        screen: String, payload: String, glyph: String = "❯", placeholder: String? = nil,
        chip: String? = nil, ourChips: Set<String> = []
    ) -> PromptLine {
        // THE WHOLE BOX, not the glyph's own row. Measured 26 Aug against
        // Claude Code 2.1.246, from a live pane holding five glued copies of
        // a message that was never sent:
        //
        //     ❯\u{00A0}
        //       I think A sounds plausible, but I want to make sure, …
        //       would actually change what we expect. …
        //
        // The caret sits alone on its row and the text begins on the next
        // one. Reading only the glyph row, `content` was empty and a box
        // holding five paragraphs classified as `.empty` — so `decide`
        // answered `.paste`, every attempt pasted another copy, nothing ever
        // cleared (clearing only happens on `.holds`), and the Return was
        // never reached because the echo check cannot match five copies
        // against one payload. Five pastes, no send, "couldn't confirm it
        // landed", and the user's words left sitting in the box.
        //
        // `boxRows` already read continuation rows correctly and is what
        // `boxHolds` has used since 23 Aug; this function simply was not
        // asking it. The emptiness test is the one that has to be
        // row-aware, because it short-circuits every check below it — a
        // wrong `.empty` is not a missed observation, it is permission to
        // paste again.
        guard let rows = boxRows(screen: screen, glyph: glyph) else { return .empty }
        let content = collapsed(rows.joined(separator: " "))
        if content.isEmpty { return .empty }
        // A live bug, found only by actually dispatching to a real idle
        // Codex composer (22 Aug): its own idle hint text ("Ask Codex to do
        // anything") renders on the SAME glyph-prefixed line an empty box
        // would, plain-text-indistinguishable from something a human
        // typed — `capture-pane -p` carries no color/dimness to tell a
        // greyed-out placeholder apart from real input. Read literally, an
        // idle composer classified as `.holds(ours: false)` — floor held by
        // a "message" nobody wrote, refusing every dispatch permanently.
        // `placeholder`, when the caller's harness has one, is checked
        // BEFORE the payload match below: an exact match to the harness's
        // OWN known idle string reads as genuinely empty, never as someone
        // else's floor.
        if let placeholder, content == placeholder { return .empty }
        // A chip THIS send drew is our own unsubmitted paste wearing the
        // only clothes the TUI gave it. Without this, the branch below
        // reads `[Pasted text #10]` as a stranger's floor, clears it,
        // pastes again, draws `#11`, and repeats until the attempts run
        // out — the exact loop measured live on 23 Aug: five pastes, no
        // Return, twelve seconds, "couldn't confirm it landed." Checked
        // against chips we KNOW we drew, never against the SHAPE of a
        // chip: a paste the human made before we arrived is still theirs.
        if !ourChips.isDisjoint(with: pasteChips(screen: screen, glyph: glyph, chip: chip)) {
            return .holds(ours: true)
        }
        // Row-aware before line-aware: a payload the TUI drew across
        // several rows is fully readable as rows, and only its first row
        // survives the single-line `content` below.
        if !payload.isEmpty, boxHolds(payload: payload, screen: screen, glyph: glyph) {
            return .holds(ours: true)
        }
        // A truncated echo is a PREFIX of what we sent — the TUI elides
        // trailing characters while long input renders — never the reverse,
        // and never an unanchored substring test. `payload.contains(content)`
        // used to accept ANY shared substring in either direction: a human's
        // half-typed "go" on the floor classified as OURS against a
        // dispatched "go ahead and merge it" and got Enter pressed under it
        // (codebase audit finding, 21 Aug — this is the exact splice
        // `floorHeld` exists to prevent, arrived at from the other side).
        // The length floor keeps a short, coincidental prefix match from
        // reading as truncation evidence when it is more likely chance.
        if !payload.isEmpty,
           content.contains(payload)
           || (content.count >= 8 && payload.hasPrefix(content)) {
            return .holds(ours: true)
        }
        return .holds(ours: false)
    }

    /// Dedupe makes within-send retries safe, and the watermark keeps it
    /// honest: "already delivered" means delivered by THIS send — an earlier
    /// attempt's paste that landed while its Enter was in doubt — never a
    /// lookalike from history.
    private func alreadyDelivered(_ payload: String, target: DispatchTarget,
                                  fromByteOffset watermark: Int64) -> Bool {
        // Branches on the transcript's own schema, not just which path to
        // read: a Codex rollout parses through CodexRollout, never Claude
        // Code's `{"type":"user",…}` line shape — reading it with the
        // wrong parser found zero messages, always, deterministically
        // (found live, 22 Aug, not reasoned about in advance).
        if target.readinessSource == .rolloutTail {
            guard let path = target.transcriptPath else { return false }
            return TranscriptWatcher.codexUserMessages(in: path, fromByteOffset: watermark)
                .contains { $0.contains(payload) }
        }
        guard let path = target.transcriptPath
            ?? TranscriptArchive.transcriptPath(forSessionId: target.sessionId)
        else { return false }
        return TranscriptWatcher.userMessages(in: path, fromByteOffset: watermark)
            .contains { $0.contains(payload) }
    }

    private func landedInTranscript(
        _ payload: String, target: DispatchTarget, timeout: TimeInterval? = nil,
        fromByteOffset watermark: Int64
    ) async -> Bool {
        if target.readinessSource == .rolloutTail {
            guard let path = target.transcriptPath else { return false }
            return await TranscriptWatcher.waitForCodexUserText(
                payload, path: path, timeout: timeout ?? verificationTimeout,
                pollInterval: pollInterval, fromByteOffset: watermark)
        }
        return await TranscriptWatcher.waitForUserText(
            payload, sessionId: target.sessionId, knownPath: target.transcriptPath,
            timeout: timeout ?? verificationTimeout, pollInterval: pollInterval,
            fromByteOffset: watermark)
    }

    private func poll(deadline: TimeInterval, every: TimeInterval,
                      until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: every)
        }
        return condition()
    }
}
