import Foundation

// MARK: - Target

/// Where a reply is going. Resolved fresh at dispatch time, never trusted from
/// when the summary was announced — tabs close and pids get recycled.
public struct DispatchTarget: Sendable, Equatable {
    public enum ReadinessSource: String, Sendable {
        /// Real Claude Code session: presence in `claude agents --json` is the gate.
        case claudeAgents
        /// Test harness: the process being alive is the gate.
        case processAlive
        /// Codex session: `HarnessCapabilities.registersWithLiveness == false`
        /// — no `agents --json` equivalent exists, so busy/idle comes from
        /// tailing the session's own rollout file (`CodexRollout.parse`)
        /// instead of a CLI-reported status. The process-alive check every
        /// transport already runs before consulting `readinessSource` is
        /// what covers `CodexRollout.Parsed.isBusy`'s own documented gap (a
        /// process killed mid-turn reads identically to one still working,
        /// from the rollout alone) — `.targetGone` fires first; this case is
        /// only reached once the process is confirmed alive.
        case rolloutTail
    }

    public var kind: TransportKind
    public var sessionId: String
    public var pid: Int?
    /// A DISPLAY and identity-guard fact only, never an address. Two dead
    /// Terminal windows once matched a tty the tmux server had recycled and a
    /// reply was typed into a corpse (19 Aug misfire); addressing is the
    /// transport's own live handle — a Terminal tab walked fresh, a tmux
    /// `pane` below — resolved at dispatch time.
    public var tty: String?
    /// The live tmux pane behind `pid`, when a tmux server owns it. Resolved
    /// fresh by `TmuxOwnership.pane(forPid:)` at target construction; its
    /// presence is what selects the tmux transport.
    public var pane: TmuxPaneAddress?
    public var transcriptPath: String?
    public var label: String?
    public var readinessSource: ReadinessSource
    /// The glyph `TmuxTransport`'s floor check (`classifyPromptLine`) looks
    /// for to find the input box on screen — Claude Code's TUI draws `❯`,
    /// Codex's draws `›` (`CodexAdapter.capabilities.promptGlyph`, measured
    /// live 21 Aug). Defaults to Claude Code's own, so every existing
    /// construction site keeps meaning exactly what it always has; a caller
    /// building a target for a different harness passes its adapter's glyph.
    public var promptGlyph: String
    /// The harness's own idle-composer hint text, when it has one that
    /// renders on the SAME glyph-prefixed line an empty box would — found
    /// live, 22 Aug, dispatching to a real idle Codex composer: its
    /// placeholder ("Ask Codex to do anything") is plain-text-
    /// indistinguishable from something a human typed (`capture-pane -p`
    /// carries no color/dimness), so the floor check read an idle session
    /// as permanently held. nil for Claude Code (no placeholder text
    /// measured on its own idle composer) and every existing construction
    /// site, unchanged.
    public var idlePlaceholder: String?
    /// The harness's paste chip prefix — see
    /// `HarnessCapabilities.pasteChipPrefix`, whose measurement this
    /// carries to the transport. Defaults to Claude Code's own, like
    /// `promptGlyph` above, so every existing construction site keeps
    /// meaning what it always has.
    public var pasteChip: String?

    public init(
        kind: TransportKind = .tmux,
        sessionId: String,
        pid: Int? = nil,
        tty: String? = nil,
        pane: TmuxPaneAddress? = nil,
        transcriptPath: String? = nil,
        label: String? = nil,
        readinessSource: ReadinessSource = .claudeAgents,
        promptGlyph: String = "❯",
        idlePlaceholder: String? = nil,
        pasteChip: String? = "[Pasted text #"
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.pid = pid
        self.tty = tty
        self.pane = pane
        self.transcriptPath = transcriptPath
        self.label = label
        self.readinessSource = readinessSource
        self.promptGlyph = promptGlyph
        self.idlePlaceholder = idlePlaceholder
        self.pasteChip = pasteChip
    }
}

// MARK: - Outcomes

public enum Readiness: Sendable, Equatable {
    /// Safe to inject.
    case ready
    /// Process is alive but absent from `claude agents --json`. Verified meaning:
    /// the session is blocked on a dialog (trust prompt, permission prompt) or is
    /// still starting. Injecting here would ANSWER the dialog — never do it.
    case notRegistered
    /// Mid-turn. Claude Code accepts typed input while it works and queues it as
    /// the next message, which is exactly what a person does: you type your reply
    /// while it is still going. Deferring here bounced a perfectly good reply for
    /// no reason, so `busy` dispatches.
    case busy
    /// Explicitly waiting on the user for something. Dispatchable, EXCEPT when
    /// what it is waiting at is a dialog — see `isDialog`. Waiting is otherwise
    /// the state most in need of an answer.
    case waiting(String?)
    /// The process is gone.
    case targetGone
    /// Somebody's half-typed text is sitting in the session's input box — the
    /// human's, or a message they queued mid-turn. Pasting now would splice
    /// our words into theirs, which is a corruption, not a delivery. tmux
    /// transport only; the AppleScript transport cannot see the input box.
    case floorHeld

    /// What `waitingFor` says when the session is sitting at a modal dialog.
    /// The CLI's own word, matched exactly rather than by substring: this
    /// decides whether text is typed at a menu, and a loose match is how a new
    /// value would quietly acquire that power.
    public static let dialogOpen = "dialog open"

    /// The other three of the five DOCUMENTED `waitingFor` values (code.claude.com/
    /// docs/en/agent-view) that are the same hazard as `dialogOpen` under a
    /// different name: a structural yes/no gate, not a free-text answer. Added
    /// 23 Aug (2026-08-23-agent-session-transport report) — until this only
    /// `dialogOpen` was VERIFIED live, and `isDialog`'s own doc comment says why
    /// that was deliberately narrow rather than an oversight: "only the value we
    /// have seen refuses." These three are now seen, documented at Tier 1, not
    /// guessed. Same reasoning ACP's spec draws between `session/
    /// request_permission` and `elicitation/create`: a permission decision is
    /// security, not a question, and typing a voice transcript at it does not
    /// mean what typing an answer to a question means. Before this fix,
    /// `canDispatch` waved a reply straight through to a live permission
    /// prompt — untyped keys landing on an unread security gate, the same
    /// shape of hazard the resume-prompt fix (19 Aug) closed for `dialogOpen`.
    public static let permissionPrompt = "permission prompt"
    public static let sandboxRequest = "sandbox request"
    public static let workerRequest = "worker request"
    /// The fifth documented value. Genuinely free-text-answerable — Claude
    /// asking a real question, `AskUserQuestion`'s own shape — so it is NOT
    /// added to `dialogLikeValues` below; it takes the same path `.question`
    /// always has, unchanged.
    public static let inputNeeded = "input needed"

    private static let dialogLikeValues: Set<String> = [
        dialogOpen, permissionPrompt, sandboxRequest, workerRequest,
    ]

    /// Whether this state is a session sitting at a dialog, whatever route it
    /// was detected by. `WaitingAt` classifies the same field for the lamp, from
    /// the same constants, so the row and the send path cannot disagree about
    /// what a session is stuck at.
    public var isDialog: Bool {
        switch self {
        case .notRegistered: return true
        case .waiting(let what): return what.map { Self.dialogLikeValues.contains($0) } ?? false
        case .ready, .busy, .targetGone, .floorHeld: return false
        }
    }

    /// The hazard is a DIALOG, and until 19 Aug it was recognised only by its
    /// old symptom.
    ///
    /// The rule has always been right — typed text at a modal ANSWERS it rather
    /// than reaching the prompt — but the witness went stale. Being absent from
    /// `claude agents --json` was how a blocked session used to look; the CLI
    /// now registers it and says so outright. Measured 19 Aug on a real one:
    /// `status: waiting · waitingFor: dialog open`, a session sitting at the
    /// resume prompt, which `canDispatch` waved through because it read the
    /// status and not the reason. That prompt's default is "resume full session
    /// as-is", so a dictated reply landing on it would not merely be swallowed —
    /// its Return would pick the expensive option, silently, on the user's
    /// behalf.
    ///
    /// Deliberately narrow: only the value we have seen refuses. Inverting it —
    /// dispatching only for known-good values — would defer every reply to an
    /// `AskUserQuestion`, which is the app's daily loop, on the strength of a
    /// string nobody has verified.
    ///
    /// The one mapping from the CLI's status vocabulary to a readiness verb,
    /// shared by every transport so the gate cannot fork. nil means the
    /// session is absent from the probe: blocked on a dialog, or gone.
    public static func classify(_ live: LiveSession?) -> Readiness {
        guard let live else { return .notRegistered }
        switch live.status {
        case "idle": return .ready
        case "busy": return .busy
        case "waiting": return .waiting(live.waitingFor)
        default: return .notRegistered
        }
    }

    /// The Codex equivalent of `classify(_:LiveSession?)` above — same
    /// shape, different ground truth. No rollout found (nil — the session
    /// hasn't written its first turn yet, or the id is wrong) fails closed
    /// the same way an absent `LiveSession` does: `.notRegistered`, refuse
    /// rather than guess, matching "typing fails CLOSED" everywhere else in
    /// this file. Deliberately narrower than the Claude Code mapping: no
    /// Codex-specific dialog/waiting state is read here — nothing measured
    /// yet distinguishes "idle" from "sitting at a mid-turn dialog" the way
    /// `waitingFor` does for Claude Code, so that hazard, if it exists at
    /// all, is not covered by this classification. An honest gap, not a
    /// silent one — `Readiness.waiting` is simply never produced from a
    /// rollout.
    public static func classify(rollout parsed: CodexRollout.Parsed?) -> Readiness {
        guard let parsed else { return .notRegistered }
        return parsed.isBusy ? .busy : .ready
    }

    /// `floorHeld` refuses for its own reason: pasting would splice our words
    /// into somebody's half-typed message. Same gate, different hazard.
    public var canDispatch: Bool {
        switch self {
        case .ready, .busy: return true
        case .waiting: return !isDialog
        case .notRegistered, .targetGone, .floorHeld: return false
        }
    }
}

public enum DispatchFailure: Error, Sendable, Equatable {
    case notEnrolled(String)
    case targetGone
    case tabNotFound(String)
    case injectionFailed(String)
    /// We sent the keystrokes but never saw the text land. AMBIGUOUS — it may have
    /// arrived. Never auto-retried; a duplicate injection is worse than a drop.
    case verificationTimedOut
}

public enum DispatchOutcome: Sendable {
    case confirmed(latencyMs: Int)
    /// Typed into a session that was mid-turn. Claude Code holds it in the input box
    /// and sends it when the turn ends, so it cannot appear in the transcript yet.
    /// This is a success with a delay, and must not be reported as the ambiguous
    /// case: nothing is in doubt except when.
    case queued
    case deferred(Readiness)
    case failed(DispatchFailure)
}

// MARK: - Transport

/// One implementation per terminal emulator. Callers only ever see this surface,
/// so adding iTerm2 / WezTerm / kitty / tmux later touches nothing upstream.
public protocol DispatchTransport: Sendable {
    var kind: TransportKind { get }
    func readiness(for target: DispatchTarget) async -> Readiness
    /// Full sequence: pre-flight, inject, submit, verify. Never partial.
    func send(text: String, to target: DispatchTarget) async -> DispatchOutcome
}

// MARK: - Text preparation

public enum DispatchText {
    /// Claude Code's TUI submits on Enter, and a two-line injection lands as two
    /// partial prompts (verified). Dictated replies are frequently multi-sentence,
    /// so newlines are collapsed before they ever reach the terminal.
    public static func flatten(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escape for embedding inside an AppleScript string literal.
    public static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - Support

public struct ScriptError: Error, Sendable, CustomStringConvertible {
    public let message: String
    /// True when the script was killed by our own deadline rather than failing
    /// on its own — the caller's "Terminal is busy" case, distinct from a
    /// genuine scripting error.
    public let timedOut: Bool
    /// Whether running the same call again could plausibly do anything
    /// different. Default true, because most failures here are a busy
    /// Terminal or a slow Apple event and always were.
    ///
    /// False is the case named 24 Aug: a launched command that EXITED on its
    /// own, with a status. `zsh` exiting 127 on a missing binary will exit
    /// 127 again, every time, and a card offering "try again" over that is
    /// sending its reader in a circle. Distinguishing them is the difference
    /// between an offer and a loop.
    public let worthRetrying: Bool
    public var description: String { message }

    public init(message: String, timedOut: Bool = false, worthRetrying: Bool = true) {
        self.message = message
        self.timedOut = timedOut
        self.worthRetrying = worthRetrying
    }
}

/// A Data accumulator that is safe to fill from a GCD drain thread and read
/// after the drain's group has been waited out.
private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Fires exactly once, from whichever thread gets there first.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// True exactly once.
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
    var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
}

/// FileHandle is not Sendable; the drain thread is its only user after launch.
private struct DrainHandle: @unchecked Sendable { let handle: FileHandle }

public enum AppleScript {
    /// Both pipes are drained CONCURRENTLY with the wait, never after it: a
    /// child that writes more than the 64 KB pipe buffer otherwise blocks on
    /// the pipe while the parent blocks in waitUntilExit — a permanent
    /// deadlock (issue 14). The drains run on GCD threads, not the Swift
    /// cooperative pool.
    private static func launchDraining(
        _ p: Process, _ out: Pipe, _ err: Pipe
    ) throws -> (stdout: PipeBuffer, stderr: PipeBuffer, drained: DispatchGroup) {
        try p.run()
        let stdout = PipeBuffer(), stderr = PipeBuffer()
        let drained = DispatchGroup()
        for (pipe, buf) in [(out, stdout), (err, stderr)] {
            let reader = DrainHandle(handle: pipe.fileHandleForReading)
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                buf.append(reader.handle.readDataToEndOfFile())
                drained.leave()
            }
        }
        return (stdout, stderr, drained)
    }

    private static func osascript(_ script: String) -> (Process, Pipe, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        return (p, out, err)
    }

    /// Synchronous, unbounded. Only for callers already off the main thread
    /// whose scripts cannot stall; anything user-facing wants the async
    /// variant below, which owns a deadline.
    public static func run(script: String) -> Result<String, ScriptError> {
        let (p, out, err) = osascript(script)
        let stdout: PipeBuffer, stderr: PipeBuffer, drained: DispatchGroup
        do { (stdout, stderr, drained) = try launchDraining(p, out, err) }
        catch { return .failure(ScriptError(message: "\(error)")) }
        p.waitUntilExit()
        drained.wait()
        return p.terminationStatus == 0
            ? .success(stdout.text)
            : .failure(ScriptError(message: stderr.text))
    }

    /// A one-slot promise: the termination handler deposits the exit status
    /// from its own thread, the async caller collects it — whichever side
    /// arrives second completes the hand-off, so setting the handler before
    /// run() can never lose an instant exit.
    private final class ExitPromise: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var waiter: CheckedContinuation<Int32, Never>?
        func exit(_ s: Int32) {
            lock.lock()
            if let w = waiter { waiter = nil; lock.unlock(); w.resume(returning: s) }
            else { status = s; lock.unlock() }
        }
        func wait(_ c: CheckedContinuation<Int32, Never>) {
            lock.lock()
            if let s = status { lock.unlock(); c.resume(returning: s) }
            else { waiter = c; lock.unlock() }
        }
    }

    /// Bounded and off-thread: awaits the child without blocking any thread,
    /// and kills it (SIGTERM, then SIGKILL half a second later) when the
    /// deadline passes. An Apple event against a busy target is entitled to
    /// block for its full two-minute default timeout; no user-facing surface
    /// can be made to wait on that (issue 14).
    public static func run(
        script: String, timeout: TimeInterval
    ) async -> Result<String, ScriptError> {
        let (p, out, err) = osascript(script)
        let promise = ExitPromise()
        let exited = OnceFlag(), killed = OnceFlag()
        p.terminationHandler = { proc in
            _ = exited.fire()
            promise.exit(proc.terminationStatus)
        }
        let stdout: PipeBuffer, stderr: PipeBuffer, drained: DispatchGroup
        do { (stdout, stderr, drained) = try launchDraining(p, out, err) }
        catch { return .failure(ScriptError(message: "\(error)")) }

        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard !exited.didFire, killed.fire() else { return }
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if !exited.didFire { kill(pid, SIGKILL) }
            }
        }

        let status = await withCheckedContinuation { promise.wait($0) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            drained.notify(queue: .global()) { cont.resume() }
        }
        if killed.didFire {
            return .failure(ScriptError(
                message: "osascript killed after \(Int(timeout))s deadline",
                timedOut: true))
        }
        return status == 0
            ? .success(stdout.text)
            : .failure(ScriptError(message: stderr.text))
    }
}

public enum ProcessProbe {
    public static func isAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Controlling terminal of a process, as `/dev/ttysNNN`.
    public static func tty(of pid: Int) -> String? {
        guard case .success(let raw) = Subprocess.run(
            "/bin/ps", ["-o", "tty=", "-p", "\(pid)"], timeout: 3),
              !raw.isEmpty, raw != "??" else { return nil }
        return raw.hasPrefix("/dev/") ? raw : "/dev/\(raw)"
    }

    /// The reverse of `tty(of:)`: which pid on a tty has `needle` in its
    /// command line — how `attemptCodexResume` finds the REAL agent process
    /// behind a freshly-spawned tmux pane, not tmux's own `#{pane_pid}`.
    ///
    /// Measured live, 22 Aug: `launchTmux`'s command is always
    /// `/bin/zsh -c "cd 'dir' && <command> <args>"`, a compound statement,
    /// which looked like it should leave a wrapping zsh pid distinct from
    /// the harness's own — it does not. zsh's own last-command exec
    /// optimization replaces the shell with the final command even inside a
    /// `&&` chain, confirmed against both launch shapes this app uses (a
    /// bare command, and `cd X && command args`): the harness sits directly
    /// on the tty every time. Matching a NEEDLE (the session id, present in
    /// any resume argv) rather than a binary-name prefix, because a
    /// harness's own children can share the tty — measured live: a resumed
    /// Codex process on this machine spawned its own MCP-server children on
    /// the same tty, and a prefix match on "codex" alone would have no way
    /// to prefer the parent over them.
    public static func pid(onTty tty: String, containing needle: String) -> Int? {
        guard !needle.isEmpty else { return nil }
        let short = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard case .success(let raw) = Subprocess.run(
            "/bin/ps", ["-t", short, "-o", "pid=,command="], timeout: 3)
        else { return nil }
        return matchPid(psOutput: raw, containing: needle)
    }

    /// Pure half, testable against captured `ps` text without a live
    /// process table — the same split `TmuxOwnership.match` and
    /// `ClaudeAgentsCLI.decodeSessions` already keep between reading and
    /// deciding.
    static func matchPid(psOutput: String, containing needle: String) -> Int? {
        guard !needle.isEmpty else { return nil }
        for line in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(of: " "),
                  let pid = Int(trimmed[trimmed.startIndex..<spaceIdx])
            else { continue }
            let command = trimmed[trimmed.index(after: spaceIdx)...]
            if command.contains(needle) { return pid }
        }
        return nil
    }

}

// MARK: - claude agents --json

public struct LiveSession: Sendable, Decodable {
    public var pid: Int
    public var sessionId: String
    public var cwd: String?
    public var status: String?
    public var name: String?
    public var waitingFor: String?
    /// The CLI's own hosting discriminator: "interactive" for a person's
    /// session, "background" for one hosted by `claude --bg-pty-host` with no
    /// tab and no supported input channel (PR #1 measured the correlation
    /// across 11 live sessions; docs/log/open-issues.md §1 named decoding it "the
    /// fourth guess that finally has evidence behind it"). Optional so a CLI
    /// that stops emitting it costs one rule rather than every row, and the
    /// asymmetry matches the sdk-cli filter: exclusion needs POSITIVE
    /// evidence, so nil reads as interactive.
    public var kind: String?
    /// When this PROCESS came up, in milliseconds since the epoch, as the CLI
    /// reports it. Read since 19 Aug because it answers a question nothing
    /// else in the system could: whether the conversation in the file was
    /// written by the process that is running now, or by one that has since
    /// been killed. See `AgentRestart`. Optional, so a CLI that stops emitting
    /// it costs one rule rather than every row.
    public var startedAt: Double?

    public var startedAtDate: Date? {
        startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Positive evidence of a tab-less first-party background session. Only
    /// the literal string counts — an unknown future value is somebody's
    /// session, the same fail-open shape as `SessionDiscovery.isHeadless`.
    public var isBackground: Bool { kind == "background" }
}

extension Array where Element == LiveSession {
    /// The one row that IS this pid — sessionId alone stopped being unique
    /// the day dual-live proved safe: Claude Code tolerates two processes
    /// resuming the same conversation (its own "Remote Control" arbitrates
    /// exactly this), so `agents --json` can legitimately return two rows
    /// sharing a sessionId with different pids. A transport probing readiness
    /// always already knows which pid it is about to type into — Coordinator
    /// resolved that once, deterministically — so matching sessionId alone
    /// here risked reading the OTHER process's busy/dialog state and
    /// deferring or answering a dialog that belongs to somebody else's
    /// terminal. Matching both closes it without a live-server call.
    public func matching(sessionId: String, pid: Int) -> LiveSession? {
        first(where: { $0.sessionId == sessionId && $0.pid == pid })
    }
}

public protocol ClaudeAgentsReading: Sendable {
    /// nil means "could not determine", which is different from "none" — and the
    /// difference is load-bearing. Collapsing failure into an empty list made one
    /// CLI hiccup silently hide every waiting session: the filter treated "I don't
    /// know" as "nobody is home". Callers decide the failure direction themselves,
    /// because it differs: announcing fails OPEN (show the work), typing fails
    /// CLOSED (never inject into a session you cannot verify).
    func sessions() -> [LiveSession]?
}

public struct ClaudeAgentsCLI: ClaudeAgentsReading {
    public init() {}

    /// Locate the `claude` binary without relying on PATH.
    ///
    /// A GUI-launched app inherits a minimal environment, not your shell's, so
    /// `claude` is simply not on PATH there — the lookup silently returned no
    /// sessions and the app could not resolve a single tab, while the same code
    /// worked from the terminal. Search the known install locations directly.
    public static func resolveBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Last resort: ask a login shell, which does read the user's profile —
        // bounded, because a blocking ~/.zprofile used to hang liveness forever.
        return Subprocess.loginShellWhich("claude")
    }

    /// Set by the app so a failing liveness probe explains itself. Every previous
    /// failure here was invisible: [] on error looked identical to [] on success.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// Last good answer, kept briefly. The badge, the announcer and the ambient
    /// refresh all ask within the same tick; one subprocess per tick is plenty, and
    /// a shorter failure window is a correctness feature here, not a performance one.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [LiveSession]?
        private var at = Date.distantPast
        func get(maxAge: TimeInterval) -> [LiveSession]? {
            lock.lock(); defer { lock.unlock() }
            guard Date().timeIntervalSince(at) < maxAge else { return nil }
            return value
        }
        func put(_ sessions: [LiveSession]) {
            lock.lock(); value = sessions; at = Date(); lock.unlock()
        }
        func clear() {
            lock.lock(); value = nil; at = .distantPast; lock.unlock()
        }
    }
    private static let cache = Cache()

    /// Drop the cached answer, so the next `sessions()` asks the CLI.
    ///
    /// Six seconds of staleness is right for the badge and the ambient refresh,
    /// which ask constantly and can afford to be a tick behind. It is wrong
    /// either side of a kill: before one, a cached pid can already belong to
    /// somebody else (which is why `SessionTermination` re-reads `ps` rather
    /// than trusting this at all); after one, the grid would keep drawing a lit
    /// lamp for a session the user just ended, and a row that ignores a click
    /// for six seconds reads as a broken control rather than a cached one.
    public static func invalidate() { cache.clear() }

    /// One row per live session, decoded LENIENTLY: a row this build cannot
    /// decode is dropped and traced, never allowed to nil the whole probe.
    /// The old all-or-nothing decode meant one future session kind could
    /// refuse every reply on the machine at once (audit R4) — the same
    /// per-row asymmetry `LiveSession.kind` itself documents, applied at the
    /// array level.
    private struct LenientRow: Decodable {
        let session: LiveSession?
        init(from decoder: Decoder) {
            session = try? LiveSession(from: decoder)
        }
    }

    public func sessions() -> [LiveSession]? {
        if let cached = Self.cache.get(maxAge: 6) { return cached }
        guard let binary = Self.resolveBinary() else {
            Self.trace?("liveness: claude binary not found")
            return nil
        }
        // Bounded: a wedged CLI here used to block whichever thread asked,
        // every tick, for as long as the wedge lasted (audit R5).
        switch Subprocess.run(binary, ["agents", "--json"], timeout: 8) {
        case .failure(let error):
            Self.trace?("liveness: \(error.timedOut ? "deadline" : "probe failed"): \(error.message.prefix(160))")
            return nil
        case .success(let out):
            guard let sessions = Self.decodeSessions(out, trace: Self.trace) else { return nil }
            Self.cache.put(sessions)
            return sessions
        }
    }

    /// Lenient at the row, honest at the array: dropped rows are traced, and
    /// a probe where EVERY row failed returns nil ("could not determine"),
    /// never [] ("nobody is home") — the exact nil-vs-empty distinction this
    /// protocol documents as load-bearing, applied at the boundary a future
    /// CLI schema change would hit first (M1 gate finding V1). Internal so
    /// the tests exercise THIS code, not a copy (finding V12).
    static func decodeSessions(_ body: String, trace: (@Sendable (String) -> Void)?) -> [LiveSession]? {
        guard let data = body.data(using: .utf8),
              let rows = try? JSONDecoder().decode([LenientRow].self, from: data)
        else {
            trace?("liveness: decode failed: body=\(body.prefix(120))")
            return nil
        }
        let sessions = rows.compactMap(\.session)
        let dropped = rows.count - sessions.count
        if dropped > 0 {
            trace?("liveness: dropped \(dropped) undecodable row(s) of \(rows.count)")
        }
        if sessions.isEmpty, !rows.isEmpty {
            trace?("liveness: ALL \(rows.count) rows undecodable — treating as unknown, not empty")
            return nil
        }
        return sessions
    }
}

// MARK: - Read-back verification

public enum TranscriptWatcher {

    /// The transcript's size right now — the delivery watermark.
    ///
    /// Taken at send() entry by both transports, and every verification and
    /// dedupe read afterwards starts from it. The rule it encodes: a payload
    /// that ever appeared in HISTORY is not evidence about THIS delivery;
    /// only bytes appended after dispatch start are. Without it, a short
    /// reply ("yes", "go ahead") that appeared in any earlier message
    /// false-confirmed without sending — found by the 19 Aug architecture
    /// audit, in code that had passed a 100-message validation battery whose
    /// payloads all happened to be unique.
    ///
    /// nil or missing path reads as 0: a transcript that does not exist yet
    /// has no history to exclude, and the first-reply case (file born WITH
    /// our message) keeps working unchanged.
    public static func fileSize(atPath path: String?) -> Int64 {
        guard let path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64
        else { return 0 }
        return size
    }

    /// True once `text` appears as a user message appended at or after
    /// `fromByteOffset`.
    public static func waitForUserText(
        _ text: String, in path: String, timeout: TimeInterval, pollInterval: TimeInterval,
        fromByteOffset: Int64 = 0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while Date() < deadline {
            if userMessages(in: path, fromByteOffset: fromByteOffset)
                .contains(where: { $0.contains(needle) }) { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }

    /// The same wait, for a transcript that may not exist yet.
    ///
    /// A session registers with `claude agents --json` before it has written a
    /// line, and Claude Code creates `<sessionId>.jsonl` when the FIRST user
    /// message lands — which is the very message this is watching for. Requiring
    /// the path in advance therefore made a session's first reply unverifiable by
    /// construction, so the path is looked up on every poll until it appears.
    ///
    /// `knownPath` short-circuits the lookup for callers that already hold one
    /// (an established session, and the test harness, whose transcripts do not
    /// live under `~/.claude/projects` at all). A path that is known but not yet
    /// on disk is still fine: `userMessages` reads a missing file as no messages.
    public static func waitForUserText(
        _ text: String, sessionId: String, knownPath: String?,
        timeout: TimeInterval, pollInterval: TimeInterval,
        projects: URL = TranscriptArchive.projectsDirectory,
        fromByteOffset: Int64 = 0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = knownPath
        while Date() < deadline {
            // Re-resolved rather than resolved once: the whole point is that the
            // file arrives DURING the wait. Once found it is kept — the id names
            // one file for the life of the session.
            if path == nil {
                path = TranscriptArchive.transcriptPath(forSessionId: sessionId,
                                                        projects: projects)
            }
            if let path, userMessages(in: path, fromByteOffset: fromByteOffset)
                .contains(where: { $0.contains(needle) }) {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }

    /// Handles both real Claude transcripts (content is a string or a block array)
    /// and the simpler shape written by `tbase-test-target`.
    public static func userMessages(in path: String) -> [String] {
        userMessages(in: path, fromByteOffset: 0)
    }

    /// The same read, starting at a byte offset — the tail from a watermark.
    ///
    /// This is also what stops verification re-reading a whole transcript on
    /// every 100ms poll (they reach hundreds of megabytes; see
    /// SessionActivity's tail discipline, which this mirrors from the other
    /// direction). An offset that bisects a record mid-append is safe by
    /// construction: the fragment fails JSON parse and is skipped, and the
    /// record it belonged to began before the watermark, so excluding it is
    /// not a loss — it is the point.
    public static func userMessages(in path: String, fromByteOffset offset: Int64) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        if offset > 0 {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return [] }
        }
        guard let data = try? handle.readToEnd(),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        var found: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // A message typed into a session that is mid-turn does not become
            // a `user` record until the turn ends — it goes to the TUI's own
            // queue first. Claude Code writes that decision down:
            //
            //   {"type":"queue-operation","operation":"enqueue",
            //    "timestamp":…,"sessionId":…,"content":"…"}
            //
            // which is a FIRST-HAND record, by the program that took the
            // message, that it has the message. Counting it is not a
            // relaxation of the evidence standard; it is a stricter witness
            // than the screen, and it is the one the transport was missing.
            //
            // Measured 25 Aug, and the whole point of the fix. A dispatch
            // landed at 02:06:45.576 as exactly this record; the transport
            // read only `user` lines, never saw it, and told Robert "typed it
            // into Projects, but couldn't confirm it landed" at 02:07:02 —
            // seventeen seconds after the proof was on disk. The 24 Aug
            // five-copies incident has the same root: its commit says a
            // queued message "is not in the transcript", which was true of
            // the records we were reading and not true of the file.
            //
            // Reading it also hardens `alreadyDelivered`: a busy session's
            // delivery is now provable at step 0, so the dedupe that makes
            // every retry safe works on the exact case that used to defeat it.
            if (obj["type"] as? String) == "queue-operation",
               (obj["operation"] as? String) == "enqueue",
               let content = obj["content"] as? String {
                found.append(content)
                continue
            }

            guard (obj["type"] as? String) == "user",
                  let message = obj["message"] as? [String: Any]
            else { continue }

            if let s = message["content"] as? String {
                found.append(s)
            } else if let blocks = message["content"] as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "text" {
                    if let t = b["text"] as? String { found.append(t) }
                }
            }
        }
        return found
    }

    /// The Codex twin of `userMessages(in:fromByteOffset:)` — same
    /// contract, read through `CodexRollout.parse` instead of Claude
    /// Code's own `{"type":"user",…}` line shape, which a Codex rollout
    /// never has (every line is `session_meta`/`event_msg`/
    /// `response_item`) and would silently never match, forever.
    ///
    /// A real bug, found only by actually sending to a real Codex session
    /// (22 Aug), not by reasoning about the two schemas: the send landed
    /// and got a reply, but this — reading the wrong format — could not
    /// see it, timed out, and because `alreadyDelivered`'s dedup check
    /// reads the exact same (wrong) function, retried and injected the
    /// SAME payload a second time into the live session. Two real bugs
    /// from one root cause, closed together.
    ///
    /// Safe against a byte offset that bisects a line, the same guarantee
    /// the Claude Code version documents: a truncated first fragment
    /// fails `CodexRollout.parse`'s own per-line JSON decode and is
    /// counted in `skippedLines`, never mistaken for a message.
    public static func codexUserMessages(in path: String, fromByteOffset offset: Int64) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        if offset > 0 {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return [] }
        }
        guard let data = try? handle.readToEnd(),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        return CodexRollout.parse(raw).messages
            .filter { $0.role == "user" }
            .map(\.text)
    }

    /// The Codex twin of `waitForUserText` — polls `codexUserMessages`
    /// instead. `path` is required rather than resolved by session id: a
    /// Codex `DispatchTarget` always carries its rollout path already
    /// (`CodexRollout.rolloutPath`, resolved at construction), so there is
    /// no "the file arrives during the wait" race to handle the way Claude
    /// Code's transcript-creation-on-first-message timing needed.
    public static func waitForCodexUserText(
        _ text: String, path: String, timeout: TimeInterval, pollInterval: TimeInterval,
        fromByteOffset: Int64 = 0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while Date() < deadline {
            if codexUserMessages(in: path, fromByteOffset: fromByteOffset)
                .contains(where: { $0.contains(needle) }) { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }
}
