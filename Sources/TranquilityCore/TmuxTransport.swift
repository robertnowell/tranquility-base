import Foundation

// MARK: - tmux subprocess runner

/// Every tmux invocation in the app goes through here, bounded. The pre-mortem
/// measured one send-keys call blocking 55 seconds against a pane in copy-mode
/// (once, not reproducibly) — which is exactly why no tmux call may run without
/// a deadline, the same discipline `AppleScript.run(timeout:)` earned against
/// busy Apple-events targets.
public enum Tmux {

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
    }
    private static let binaryCache = BinaryCache()

    public static func resolveBinary() -> String? {
        binaryCache.get(or: locateBinary)
    }

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

    /// The same question asked with a tty already in hand — the launcher's
    /// trust watcher holds one before any process fact exists.
    public static func pane(forTty tty: String) -> TmuxPaneAddress? {
        for socket in sockets {
            guard case .success(let out) = Tmux.run(
                ["list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{session_name}"],
                socket: socket, timeout: 3)
            else { continue }
            if let address = match(inventory: out, tty: tty, socket: socket) {
                return address
            }
        }
        return nil
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
    /// Scoped to the tmux-owned half of the ambiguity, honestly: tmux launches
    /// are opt-in (`AgentDefaults.useTmux`, off by default), so a duplicate
    /// where NEITHER row is tmux-owned — two Terminal.app-hosted processes —
    /// is the expected shape while that setting is off, not an anomaly, and
    /// still resolves arbitrarily here exactly as it did before this fix. Not
    /// a regression: Terminal.app dispatch carried the same ambiguity
    /// beforehand. Closing it needs a live Terminal.app-tab discriminator
    /// analogous to `TmuxOwnership`, which is legacy-path investment this arc
    /// is deliberately not making — the plan already deletes Terminal.app
    /// dispatch once Codex is proven (single-transport cut). More than one
    /// tmux-owned row for one sessionId is the genuine anomaly (two tmux panes
    /// cannot share a pid's tty) and is traced identically.
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
public struct TmuxTransport: DispatchTransport {
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
        }
    }

    public func send(text: String, to target: DispatchTarget) async -> DispatchOutcome {
        guard let pane = target.pane else {
            return .failed(.injectionFailed("tmux target has no pane address"))
        }
        // Local on purpose, not re-derived from `target.pid` 90 lines below:
        // the V4 dialog re-check needs this pid to run, and today it only
        // does because `readiness(for:)` already fails closed on a nil one —
        // a non-local invariant whose failure mode, if it ever changed, would
        // be the check silently skipping rather than erroring.
        guard let pid = target.pid else { return .failed(.targetGone) }
        let state = await readiness(for: target)
        let wasBusy = state == .busy
        guard state.canDispatch else {
            return state == .targetGone ? .failed(.targetGone) : .deferred(state)
        }

        let payload = DispatchText.flatten(text)
        guard !payload.isEmpty else { return .failed(.injectionFailed("empty text")) }
        let start = Date()
        // Everything appended before this instant is history, and history is
        // not evidence about this delivery. Without the watermark, a short
        // reply ("yes") that ever appeared in an earlier message
        // false-confirmed without sending — found by the 19 Aug audit hours
        // after this transport shipped. See TranscriptWatcher.fileSize.
        let watermark = TranscriptWatcher.fileSize(atPath: target.transcriptPath
            ?? TranscriptArchive.transcriptPath(forSessionId: target.sessionId))


        let attempts = 5
        for attempt in 0..<attempts {
            let lastAttempt = attempt == attempts - 1
            // Step 0 — dedupe against ground truth, EVERY attempt. This is
            // what makes every retry below safe: our payload appended after
            // the watermark is a delivery this send already made.
            if alreadyDelivered(payload, target: target, fromByteOffset: watermark) {
                return .confirmed(latencyMs: Int(Date().timeIntervalSince1970 * 1000
                    - start.timeIntervalSince1970 * 1000))
            }

            // Step 1 — the pane must exist on the live server, now.
            guard paneExists(pane) else { return .failed(.targetGone) }

            // Step 2 — copy-mode is cleared and VERIFIED cleared. Measured:
            // text sent into copy-mode is destroyed outright, not queued —
            // it never reaches the program, on screen or in transcript.
            if !clearMode(pane) {
                return .failed(.injectionFailed("pane stuck in copy-mode"))
            }

            // Step 3 — the floor check. A non-empty input line that is not
            // our payload is somebody's half-typed message (the human's, or
            // a reply they queued mid-turn); pasting would splice into it.
            switch promptLine(pane, payload: payload) {
            case .empty, .unreadable:
                break                       // unreadable fails toward pasting:
                                            // landing is verified either way
            case .holds(ours: true):
                // Our text is already sitting unsubmitted — a previous
                // attempt's paste landed and its Enter was eaten. Submit only.
                Tmux.run(["send-keys", "-t", pane.paneId, "Enter"], socket: pane.socketName)
                if await landedInTranscript(payload, target: target,
                                            fromByteOffset: watermark) {
                    return .confirmed(latencyMs: Int(Date().timeIntervalSince(start) * 1000))
                }
                continue
            case .holds(ours: false):
                return .deferred(.floorHeld)
            }

            // Step 4 — paste atomically. load-buffer over stdin means no
            // shell, no argv, no AppleScript-literal escaping, no per-key
            // interpretation; the byte-exactness was measured (1,587 chars,
            // quotes and dollar signs intact).
            guard case .success = Tmux.run(
                ["load-buffer", "-b", "tb-dispatch", "-"],
                socket: pane.socketName, stdin: Data(payload.utf8))
            else { continue }
            Tmux.run(["paste-buffer", "-b", "tb-dispatch", "-d", "-p", "-t", pane.paneId],
                     socket: pane.socketName)

            // Step 5 — the payload is VISIBLY in the pane before Enter is
            // ever pressed. This closes the gap the AppleScript transport
            // lived with (text delivered but unsubmitted looks identical to
            // text delivered and submitted): here the two are distinguishable,
            // so "couldn't confirm" stops being an outcome the mechanism
            // can produce on its own.
            // Every target echoes — Claude Code's TUI by design (verified
            // live 19 Aug), the test harness by its own write-back — so the
            // landing check is unconditional. An eaten paste is VISIBLE as
            // absence within 2s and safely retried; an invisible input
            // buffer is exactly what allowed a double-paste splice under
            // churn (measured 20 Aug, 29-in-60), so a second no-echo path
            // does not exist any more.
            guard poll(deadline: 2.0, every: 0.05, until: { screenContains(payload, pane) }) else {
                continue    // a mode race ate the paste; loop — dedupe guards the retry
            }

            // Step 6 — submit. A Return on an empty prompt does nothing, so
            // retrying Enter alone is safe; retrying the TEXT is what
            // duplicates, and dedupe (step 0) already forbids that path.
            Tmux.run(["send-keys", "-t", pane.paneId, "Enter"], socket: pane.socketName)

            // Step 7 — ground truth. A no-echo target cannot show us an
            // eaten paste, so betting the full verification window on every
            // attempt turned one eaten paste into a burned attempt and, under
            // enough churn, three burned attempts into a loud failure
            // (measured 20 Aug: 2 of 30 under the adversarial drill). Short
            // verifies on early attempts, the full window only on the last —
            // the shape the 100/100 bash validation actually ran.
            let window = lastAttempt ? verificationTimeout : 4
            if await landedInTranscript(payload, target: target, timeout: window,
                                        fromByteOffset: watermark) {
                return .confirmed(latencyMs: Int(Date().timeIntervalSince(start) * 1000))
            }
            // Enter may have been swallowed while the words arrived.
            if screenContains(payload, pane) {
                // The one-Return retry, with the #163 lesson applied: a
                // session can pop a modal between the first Enter and this
                // one, and a Return at a dialog ANSWERS it (gate finding V4).
                // Re-probe and stand down if a dialog is up.
                if target.readinessSource == .claudeAgents,
                   Readiness.classify((agents.sessions() ?? [])
                       .matching(sessionId: target.sessionId, pid: pid)).isDialog {
                    break
                }
                Tmux.run(["send-keys", "-t", pane.paneId, "Enter"], socket: pane.socketName)
                if await landedInTranscript(payload, target: target, timeout: 3,
                                            fromByteOffset: watermark) {
                    return .confirmed(latencyMs: Int(Date().timeIntervalSince(start) * 1000))
                }
            }
        }

        // A busy session cannot echo the text into its transcript until the
        // current turn ends — same doctrine as the Terminal transport.
        if wasBusy { return .queued }
        return .failed(.verificationTimedOut)
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

    private func screen(_ pane: TmuxPaneAddress) -> String? {
        guard case .success(let out) = Tmux.run(
            ["capture-pane", "-p", "-J", "-t", pane.paneId],
            socket: pane.socketName, timeout: 3) else { return nil }
        return out
    }

    private func screenContains(_ payload: String, _ pane: TmuxPaneAddress) -> Bool {
        screen(pane)?.contains(payload) ?? false
    }

    enum PromptLine: Equatable {
        case empty
        case holds(ours: Bool)
        case unreadable
    }

    /// What sits on the input line right now. The Claude Code TUI draws its
    /// input box as a `❯`-prefixed line; the last such line on screen is the
    /// box. A plain-shell target (the test harness) has no `❯` and reads as
    /// empty, which is right — its "input line" is wherever the cursor is,
    /// and the landing check in step 5 is the guard that matters there.
    private func promptLine(_ pane: TmuxPaneAddress, payload: String) -> PromptLine {
        guard let text = screen(pane) else { return .unreadable }
        return Self.classifyPromptLine(screen: text, payload: payload)
    }

    /// Pure half, testable against captured screens.
    static func classifyPromptLine(screen: String, payload: String) -> PromptLine {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
        guard let box = lines.last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") })
        else { return .empty }
        let content = box.trimmingCharacters(in: .whitespaces)
            .dropFirst()                                    // the ❯ itself
            .trimmingCharacters(in: .whitespaces)
        if content.isEmpty { return .empty }
        if !payload.isEmpty, content.contains(payload) || payload.contains(content) {
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
        await TranscriptWatcher.waitForUserText(
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
