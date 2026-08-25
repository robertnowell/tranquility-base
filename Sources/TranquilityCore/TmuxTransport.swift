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
        case .rolloutTail:
            return Readiness.classify(rollout: CodexRollout.parse(sessionId: target.sessionId))
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


        // Every paste chip THIS send has put on screen. A chip is the only
        // trace a collapsed paste leaves (see `pasteChips`), so it is also
        // the only way a later attempt can tell "my own words, still
        // unsubmitted" from "somebody else's floor" — the distinction step
        // 3 exists to make, and the one that silently stopped working the
        // moment a payload got long enough to collapse.
        var ourChips: Set<String> = []

        // Whether this send has ever seen its own words echoed into the box.
        // It is the ONLY thing that separates the two opposite facts `.empty`
        // reports with the same word — see the step 3 switch below.
        var everEchoed = false

        let attempts = 5
        attemptLoop: for attempt in 0..<attempts {
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
            // our payload used to defer the whole dispatch rather than
            // splice into it. Reversed 23 Aug, on the operator's own
            // instruction, blunt and explicit: every pane this transport
            // addresses is this machine's own terminal, there is no second
            // human it could ever belong to, and a dispatch that arrives to
            // find text already sitting there should still land — not sit
            // in `.deferred(.floorHeld)` telling the one person who could
            // ever answer it "try again in a moment" forever, which is what
            // it did in practice (found live, 23 Aug: the same session hit
            // this on every retry, because nothing was ever going to submit
            // or clear that line on its own).
            //
            // Clearing first, not concatenating — reverted the SAME day,
            // the hard way: a version that pasted onto the cursor without
            // clearing (so a genuinely different pre-existing line would
            // merge with ours) turned out to have no way to tell "someone
            // else's line" apart from "MY OWN unconfirmed paste from the
            // last retry" when `.holds(ours: true)`'s own detection missed
            // (large, multi-paragraph payloads wrap across many terminal
            // rows, which `classifyPromptLine`'s single-line capture was
            // never built to follow). Every retry that missed pasted ANOTHER
            // copy on top of the last, live-caught at four concatenated
            // copies of the same message, unsent. Clearing first means the
            // worst case is "the latest attempt's text lands," never
            // "however many retries it took, glued together" — strictly
            // safer, at the cost of the pre-existing line this branch exists
            // to preserve. A retry-safe way to keep BOTH intact needs
            // `classifyPromptLine` to actually track multi-row content
            // first; that has not been built.
            switch Self.decide(
                line: promptLine(pane, payload: payload, glyph: target.promptGlyph,
                                 placeholder: target.idlePlaceholder,
                                 chip: target.pasteChip, ourChips: ourChips),
                everEchoed: everEchoed
            ) {
            case .paste:
                break
            case .stop:
                // Submitted and accepted. The transcript may simply be behind
                // (idle), or may not see it until the current turn ends (busy).
                // Either way the words are in the tab and this send is done
                // pasting; the outcome is decided after the loop.
                if await landedInTranscript(payload, target: target,
                                            fromByteOffset: watermark) {
                    return .confirmed(latencyMs: Int(Date().timeIntervalSince(start) * 1000))
                }
                break attemptLoop
            case .clearThenPaste:
                // C-a then C-k (start-of-line, kill-to-end) rather than C-u
                // alone, since C-u only clears BACK from wherever the cursor
                // sits, and after a paste that never got submitted the
                // cursor's position is not known.
                Tmux.run(["send-keys", "-t", pane.paneId, "C-a"], socket: pane.socketName)
                Tmux.run(["send-keys", "-t", pane.paneId, "C-k"], socket: pane.socketName)
            case .returnOnly:
                // Our text is already sitting unsubmitted — a previous
                // attempt's paste landed and its Enter was eaten. Submit
                // only — but re-probe first (gate finding V4, codebase audit
                // 21 Aug: this branch has MORE elapsed time behind it than
                // step 7's own re-check, since it only runs on attempt >= 2,
                // after a full failed attempt's wait — the exact window a
                // resume-depth dialog can pop in. A Return at a dialog spends
                // a usage tier silently; standing down and retrying is free.
                if dialogIsUp(target: target, pid: pid) { break attemptLoop }
                Tmux.run(["send-keys", "-t", pane.paneId, "Enter"], socket: pane.socketName)
                if await landedInTranscript(payload, target: target,
                                            fromByteOffset: watermark) {
                    return .confirmed(latencyMs: Int(Date().timeIntervalSince(start) * 1000))
                }
                continue
            }

            // Step 4 — paste atomically. load-buffer over stdin means no
            // shell, no argv, no AppleScript-literal escaping, no per-key
            // interpretation; the byte-exactness was measured (1,587 chars,
            // quotes and dollar signs intact).
            //
            // The chips already on screen are read FIRST, so that a chip
            // seen afterwards is evidence about THIS paste and not about
            // one already sitting there — the same shape as the transcript
            // watermark two dozen lines above, and for the same reason:
            // history is not evidence about this delivery.
            let chipsBefore = Self.pasteChips(screen: screen(pane) ?? "",
                                              glyph: target.promptGlyph,
                                              chip: target.pasteChip)
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
            //
            // "Echoes" was read too literally, and the reading cost every
            // long dictated reply (found live 23 Aug, twice in one
            // afternoon: `[Pasted text #10]` and `[Pasted text #15]` left
            // sitting in the box, never sent, reported as "couldn't confirm
            // it landed"). A TUI echoes a paste in one of TWO ways — the
            // text itself, or a chip standing in for it once the paste is
            // too big to draw — and `screenContains` could only ever see
            // the first. `pasteEcho` sees both, and both are the same fact:
            // our words are in the box, Return is safe to press.
            var echo = PasteEcho.absent
            guard poll(deadline: 2.0, every: 0.05, until: {
                echo = pasteEcho(payload, pane, target: target, chipsBefore: chipsBefore)
                return echo != .absent
            }) else {
                continue    // a mode race ate the paste; loop — dedupe guards the retry
            }
            if case .chip(let token) = echo { ourChips.insert(token) }
            // Our words are in the box. From here on this send may press Return
            // again, but it may never paste again.
            everEchoed = true

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
            if stillHolding(payload, pane, target: target, ourChips: ourChips) {
                // The one-Return retry, with the #163 lesson applied: a
                // session can pop a modal between the first Enter and this
                // one, and a Return at a dialog ANSWERS it (gate finding V4).
                // Re-probe and stand down if a dialog is up.
                if dialogIsUp(target: target, pid: pid) { break attemptLoop }
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
                           target: DispatchTarget, chipsBefore: Set<String>) -> PasteEcho {
        guard let text = screen(pane) else { return .absent }
        if text.contains(payload)
            || Self.boxHolds(payload: payload, screen: text, glyph: target.promptGlyph) {
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
                              target: DispatchTarget, ourChips: Set<String>) -> Bool {
        guard let text = screen(pane) else { return false }
        if text.contains(payload)
            || Self.boxHolds(payload: payload, screen: text, glyph: target.promptGlyph) {
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

    /// What an attempt does with the input line it just read.
    enum FloorAction: Equatable {
        /// Nothing of ours is in the box and nothing of ours has ever been in
        /// it: this is the first paste of this send.
        case paste
        /// Somebody else's half-typed line, and we have not delivered yet.
        case clearThenPaste
        /// Our own words, still sitting unsubmitted. Press Return, never paste.
        case returnOnly
        /// Our words went in and the box released them — accepted. Stop.
        case stop
    }

    /// PASTE AT MOST ONCE PER SEND — the whole rule, in one pure function.
    ///
    /// `everEchoed` is what separates the two OPPOSITE facts `.empty` reports
    /// with the same word: "a fresh box, paste here" and "the box just TOOK
    /// our message." Without it they are indistinguishable, and the transport
    /// takes the destructive reading.
    ///
    /// Found live 24 Aug (session 60fbc8e7): ONE dispatch into a mid-turn
    /// session left FIVE identical messages in Claude Code's queue. A queued
    /// message is not in the transcript — step 0's and step 7's only witness —
    /// and it is not in the box either, so all five attempts read `.empty` and
    /// pasted again. `attempts = 5`, and five is what landed.
    ///
    /// Deliberately NOT a function of `wasBusy`: that is sampled once before
    /// the paste, so a session that goes busy in between would take the old
    /// path and reproduce the bug exactly. The box is observable now; the
    /// status is a memory of a moment that has passed.
    static func decide(line: PromptLine, everEchoed: Bool) -> FloorAction {
        switch line {
        case .empty, .unreadable:
            // `.unreadable` fails toward pasting only while nothing of ours
            // has landed; once it has, an unreadable screen is not permission
            // to send the message a second time.
            return everEchoed ? .stop : .paste
        case .holds(ours: true):
            return .returnOnly
        case .holds(ours: false):
            // Once ours has gone in, a line on the floor arrived AFTERWARDS
            // and belongs to somebody else. Clearing it would delete a
            // person's typing to make room for a message already delivered.
            return everEchoed ? .stop : .clearThenPaste
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
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
        guard let box = lines.last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(glyph) })
        else { return .empty }
        let content = box.trimmingCharacters(in: .whitespaces)
            .dropFirst(glyph.count)                         // the glyph itself
            .trimmingCharacters(in: .whitespaces)
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
