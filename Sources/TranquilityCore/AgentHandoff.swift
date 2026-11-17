import Foundation

/// The small pure part of continuing one live agent's work in another agent.
/// Launching remains the app's ordinary New Agent path; this type only answers
/// which agents may be the destination and what context rides the
/// destination's first explicit user message.
///
/// Until 12 Oct 2026 the destination was "the other one of two": Claude Code
/// handed off to Codex and Codex to Claude Code, and nothing else was offered.
/// Robert, the same evening, from an OpenCode row: *"I want it to be able to
/// continue with OpenCode also... including the same type of agent, it
/// effectively becomes a fork capability."* So the destination is now any
/// agent the roster offers and that can carry the fragment, the source's own
/// kind included.
public enum AgentHandoff {
    public struct Destination: Equatable, Sendable, Identifiable {
        public let harness: String
        public let label: String
        public let targetID: String
        public var id: String { targetID }

        public init(harness: String, label: String, targetID: String? = nil) {
            self.targetID = targetID ?? harness
            self.harness = harness
            self.label = label
        }
    }

    /// Every agent the user may continue into, in roster order.
    ///
    /// `ready` is the roster as the Settings grid shows it; only `.ready`
    /// tiles qualify, because a destination that first needs installing or a
    /// sign-in cannot take the message. `carriesFragment` lets the caller
    /// drop an agent whose start cannot carry words at all (crobot begins on
    /// its own compose page, and the fragment would be lost on the way).
    public static func destinations(
        ready agents: [AgentRoster.Agent],
        carriesFragment: (String) -> Bool = { _ in true }
    ) -> [Destination] {
        agents.filter { $0.standing.isReady && carriesFragment($0.id) }
            .map { Destination(harness: SavedAccountStore.shared.backend($0.id), label: $0.name, targetID: $0.id) }
    }

    /// What a person calls the harness, from the roster; the id itself for
    /// one the roster has not heard of, which is still better than a wrong
    /// name.
    public static func sourceLabel(for harness: String) -> String {
        AgentRoster.validated.first { $0.id == harness }?.name ?? harness
    }

    /// How a continuation receives the old conversation.
    ///
    /// Until 14 Nov 2026 every handoff carried a path and one sentence asking
    /// the new agent to read the end of the log. Robert: *"it should be a true
    /// fork... a deterministic copy into the session history from the old
    /// agent into the new agent."* Measured the same week: a harness's own
    /// fork is that copy (it carries every message since the last compaction,
    /// which is exactly what the old agent holds), and no harness can be
    /// handed another harness's history. So there are two ways, chosen by
    /// where the conversation can go, never by a setting.
    public enum Carry: Equatable, Sendable {
        /// The destination harness forks the source session itself. The
        /// arguments follow the configured launch command.
        case nativeFork(arguments: [String])
        /// The end of the log rides the first message, and `hq-log` reaches
        /// the rest.
        case pastedLog
    }

    /// A native fork needs the same harness reading the same store: a saved
    /// account keeps its transcripts under its own config directory, so a
    /// fork into another account would look for a session that is not there.
    public static func carry(
        sourceBackend: String,
        destination: any HarnessAdapter,
        sourceSessionId: String,
        sourceConfigDirectory: String?,
        destinationConfigDirectory: String?
    ) -> Carry {
        func standard(_ path: String?) -> String? {
            path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        }
        guard sourceBackend == destination.id,
              standard(sourceConfigDirectory) == standard(destinationConfigDirectory),
              let arguments = destination.forkArguments(sessionId: sourceSessionId),
              !arguments.isEmpty
        else { return .pastedLog }
        return .nativeFork(arguments: arguments)
    }

    /// How much of the log rides the first message, in tokens.
    ///
    /// Robert proposed 100,000. Half of that is the default because of one
    /// measurement: a fresh Claude Code session on this Mac spent 70,408
    /// input tokens before its first word (11 Nov, two forked probes), so
    /// 100,000 more would leave a 200,000-token window about 30,000 to work
    /// in. The rest of the log is one `hq-log search` away.
    public static let recentLogTokens = 50_000

    /// The end of a session log as `hq-log tail` prints it, or nil when the
    /// file or the command is missing. Deterministic: no model reads it.
    /// Spawns a process, so call it off the main actor.
    public static func recentLog(
        logPath: String,
        tokens: Int = recentLogTokens,
        command: String = SkillManifest.binDirectory.appendingPathComponent("hq-log").path
    ) -> String? {
        guard FileManager.default.fileExists(atPath: logPath),
              FileManager.default.isExecutableFile(atPath: command),
              case .success(let text) = Subprocess.run(
                command, ["tail", logPath, "--tokens", String(tokens)], timeout: 30)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A message fragment, not a command and not a second kind of launch.
    /// `reportsDirectory` is present only after the caller verified that the
    /// source session actually has a hub on disk. `directory` is where the
    /// source was working, named so a destination rooted elsewhere (OpenCode's
    /// server runs in the workspace) still knows where the files are.
    ///
    /// `recentLog` is the pasted end of the log. With it the fragment also
    /// names the three commands that reach everything older, by the same
    /// entry numbers the pasted part shows. Without it (a provider whose
    /// transcript is not a file, or a Mac without the command) the fragment
    /// is the pointer it always was.
    public static func fragment(
        sourceName: String,
        sourceHarness: String,
        sourceSessionId: String,
        directory: String? = nil,
        logLocation: String,
        recentLog: String? = nil,
        reportsDirectory: String?
    ) -> String {
        var paragraphs = [
            opening + "\(sourceName)\u{201D} "
                + "(\(sourceLabel(for: sourceHarness)), session \(sourceSessionId)).",
        ]
        if let directory {
            paragraphs.append("The work lives in:\n\(directory)")
        }
        if let recentLog {
            paragraphs.append(
                "The end of that agent's session log is pasted below, oldest entry first. "
                + "Every entry has a number. The complete log is at:\n\(logLocation)\n"
                + "The pasted part is not the whole conversation. When the user's instruction "
                + "refers to anything it does not show, search the log before you answer:\n"
                + "  hq-log outline \(sourceSessionId)            every message the user wrote, numbered\n"
                + "  hq-log search \(sourceSessionId) '<regex>'   the entries that match\n"
                + "  hq-log show \(sourceSessionId) 120-140       entries by number, in full")
        } else {
            paragraphs.append(
                "Local session logs can be found at:\n\(logLocation)\n"
                    + "Read the recent end of the log before acting.")
        }
        if let reportsDirectory {
            paragraphs.append(
                "Recent reports are available under:\n\(reportsDirectory)\n"
                + "Read the recent reports before acting.")
        }
        if let recentLog {
            paragraphs.append(logOpening + "\n" + recentLog + "\n" + logClosing)
        }
        paragraphs.append(
            "Any text following this handoff context is the user's current instruction.\n"
            + closing)
        return paragraphs.joined(separator: "\n\n")
    }

    static let logOpening = "===== session log, most recent part ====="
    static let logClosing = "===== end of session log ====="

    /// How every handoff fragment begins. One constant, read by the writer
    /// above and the reader below, so the two cannot drift apart.
    static let opening = "Please continue the work of \u{201C}"
    /// How every handoff fragment ends, before the user's own words.
    static let closing = "Propose a path forward after understanding the current state."

    /// A first message that began with a handoff, taken apart.
    public struct Continuation: Equatable, Sendable {
        /// The name the source wore when the user picked it.
        public let sourceName: String
        public let sourceSessionId: String
        /// What the user said after the handoff context, which is what the
        /// new agent is actually for. Empty when they sent the handoff alone.
        public let instruction: String
    }

    /// Whether a sent message is a continued agent's first message, and what
    /// it carried. Read from the message as sent, so it holds for every
    /// harness and every way a launch can be bound to its session.
    public static func continuation(in message: String) -> Continuation? {
        guard message.hasPrefix(opening) else { return nil }
        let afterOpening = message.dropFirst(opening.count)
        // The name ends at the LAST closing quote before " (…, session ": a
        // name may itself hold a quotation mark.
        guard let marker = afterOpening.range(of: ", session "),
              let close = afterOpening[..<marker.lowerBound].range(of: "\u{201D} (", options: .backwards)
        else { return nil }
        let name = String(afterOpening[..<close.lowerBound])
        let id = afterOpening[marker.upperBound...].prefix { $0 != ")" && !$0.isNewline }
        guard !name.isEmpty, !id.isEmpty else { return nil }
        var instruction = ""
        // The LAST closing sentence: a pasted log can hold an older handoff's
        // own, and reading the first would take the rest of the log for the
        // user's words.
        if let end = message.range(of: closing, options: .backwards) {
            instruction = message[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Continuation(sourceName: name, sourceSessionId: String(id), instruction: instruction)
    }
}
