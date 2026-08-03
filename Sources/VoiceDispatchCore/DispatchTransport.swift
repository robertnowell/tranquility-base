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
    }

    public var kind: TransportKind
    public var sessionId: String
    public var pid: Int?
    public var tty: String?
    public var transcriptPath: String?
    public var label: String?
    public var readinessSource: ReadinessSource

    public init(
        kind: TransportKind = .terminalApp,
        sessionId: String,
        pid: Int? = nil,
        tty: String? = nil,
        transcriptPath: String? = nil,
        label: String? = nil,
        readinessSource: ReadinessSource = .claudeAgents
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.pid = pid
        self.tty = tty
        self.transcriptPath = transcriptPath
        self.label = label
        self.readinessSource = readinessSource
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
    /// Explicitly waiting on the user for something. Also dispatchable: waiting is
    /// the state most in need of an answer.
    case waiting(String?)
    /// The process is gone.
    case targetGone

    /// The only real hazard is `notRegistered`: alive but absent from
    /// `claude agents --json` means blocked on a modal dialog, where typed text
    /// would ANSWER the dialog rather than reach the prompt. Everything else is a
    /// session that can take input, even if it is mid-thought.
    public var canDispatch: Bool {
        switch self {
        case .ready, .busy, .waiting: return true
        case .notRegistered, .targetGone: return false
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

// MARK: - Terminal.app

public struct TerminalAppTransport: DispatchTransport {
    public let kind: TransportKind = .terminalApp
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

        switch target.readinessSource {
        case .processAlive:
            return .ready
        case .claudeAgents:
            guard let live = agents.sessions().first(where: { $0.sessionId == target.sessionId })
            else {
                // Alive but unregistered — blocked on a dialog, or still booting.
                return .notRegistered
            }
            switch live.status {
            case "idle": return .ready
            case "busy": return .busy
            case "waiting": return .waiting(live.waitingFor)
            default: return .notRegistered
            }
        }
    }

    public func send(text: String, to target: DispatchTarget) async -> DispatchOutcome {
        let state = await readiness(for: target)
        let wasBusy = state == .busy
        guard state.canDispatch else {
            return state == .targetGone ? .failed(.targetGone) : .deferred(state)
        }
        guard let tty = target.tty else { return .failed(.tabNotFound("no tty on target")) }

        let payload = DispatchText.flatten(text)
        guard !payload.isEmpty else { return .failed(.injectionFailed("empty text")) }

        let start = Date()

        // Step 1 — deliver the text.
        switch AppleScript.run(script: injectScript(tty: tty, literal: DispatchText.appleScriptLiteral(payload))) {
        case .failure(let e): return .failed(.injectionFailed(e.message))
        case .success(let out) where out.contains("notfound"):
            return .failed(.tabNotFound(tty))
        case .success: break
        }

        // Step 2 — submit. This MUST be its own AppleEvent: `do script` delivers
        // long text without submitting it, and it then sits silently in the input
        // box while the session still reports `idle`. Verified with 1687 chars.
        //
        // The pause matters. A session mid-work is redrawing constantly, and a
        // Return arriving in the same instant as the text was dropped: the words sat
        // in the input box, unsent, looking exactly like a successful delivery.
        // Giving the TUI a moment to accept the text first is what makes the Return
        // land on a settled prompt.
        try? await Task.sleep(nanoseconds: 250_000_000)

        switch AppleScript.run(script: injectScript(tty: tty, literal: "\"\"")) {
        case .failure(let e): return .failed(.injectionFailed("submit: \(e.message)"))
        case .success: break
        }

        // Step 3 — read back. Delivery is confirmed by OUR text appearing, not by
        // the agent's reply, which is unbounded (a long tool call takes minutes).
        guard let transcriptPath = target.transcriptPath else {
            return .failed(.verificationTimedOut)
        }
        let landed = await TranscriptWatcher.waitForUserText(
            payload, in: transcriptPath, timeout: verificationTimeout, pollInterval: pollInterval)

        // One retry of the Return, and only the Return.
        //
        // If the text never appeared, the likeliest cause by far is that the submit
        // was swallowed while the words themselves arrived — which is safe to repeat,
        // because a Return on an empty prompt does nothing, whereas repeating the
        // TEXT would duplicate the message. That asymmetry is the whole reason this
        // is worth retrying at all.
        if !landed {
            _ = AppleScript.run(script: injectScript(tty: tty, literal: "\"\""))
            let landedAfterRetry = await TranscriptWatcher.waitForUserText(
                payload, in: transcriptPath, timeout: 3, pollInterval: pollInterval)
            if landedAfterRetry {
                return .confirmed(latencyMs: Int(Date().timeIntervalSince(start) * 1000))
            }
        }

        // A busy session cannot echo the text until its current turn finishes, which
        // can take minutes. Not seeing it inside the window is expected there, and
        // calling that ambiguous would make every mid-turn reply look like a
        // possible loss.
        if !landed, wasBusy { return .queued }

        return landed
            ? .confirmed(latencyMs: Int(Date().timeIntervalSince(start) * 1000))
            : .failed(.verificationTimedOut)
    }

    private func injectScript(tty: String, literal: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if (tty of t) as text is "\(tty)" then
                do script \(literal) in t
                return "ok"
              end if
            end repeat
          end repeat
          return "notfound"
        end tell
        """
    }
}

// MARK: - Support

public struct ScriptError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public enum AppleScript {
    public static func run(script: String) -> Result<String, ScriptError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(ScriptError(message: "\(error)")) }
        p.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return p.terminationStatus == 0
            ? .success(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            : .failure(ScriptError(message: stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

public enum ProcessProbe {
    public static func isAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Controlling terminal of a process, as `/dev/ttysNNN`.
    public static func tty(of pid: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", "\(pid)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, raw != "??" else { return nil }
        return raw.hasPrefix("/dev/") ? raw : "/dev/\(raw)"
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
}

public protocol ClaudeAgentsReading: Sendable {
    func sessions() -> [LiveSession]
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
        // Last resort: ask a login shell, which does read the user's profile.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: shell)
        probe.arguments = ["-lic", "command -v claude"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = Pipe()
        try? probe.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        probe.waitUntilExit()
        return out.isEmpty ? nil : out
    }

    public func sessions() -> [LiveSession] {
        guard let binary = Self.resolveBinary() else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["agents", "--json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? JSONDecoder().decode([LiveSession].self, from: data)) ?? []
    }
}

// MARK: - Read-back verification

public enum TranscriptWatcher {
    /// True once `text` appears as a user message in the transcript.
    public static func waitForUserText(
        _ text: String, in path: String, timeout: TimeInterval, pollInterval: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while Date() < deadline {
            if userMessages(in: path).contains(where: { $0.contains(needle) }) { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return false
    }

    /// Handles both real Claude transcripts (content is a string or a block array)
    /// and the simpler shape written by `dispatch-test-target`.
    public static func userMessages(in path: String) -> [String] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var found: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "user",
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
}
