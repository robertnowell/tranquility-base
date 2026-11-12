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

    /// A message fragment, not a command and not a second kind of launch.
    /// `reportsDirectory` is present only after the caller verified that the
    /// source session actually has a hub on disk. `directory` is where the
    /// source was working, named so a destination rooted elsewhere (OpenCode's
    /// server runs in the workspace) still knows where the files are.
    public static func fragment(
        sourceName: String,
        sourceHarness: String,
        sourceSessionId: String,
        directory: String? = nil,
        logLocation: String,
        reportsDirectory: String?
    ) -> String {
        var paragraphs = [
            opening + "\(sourceName)\u{201D} "
                + "(\(sourceLabel(for: sourceHarness)), session \(sourceSessionId)).",
        ]
        if let directory {
            paragraphs.append("The work lives in:\n\(directory)")
        }
        paragraphs.append(
            "Local session logs can be found at:\n\(logLocation)\n"
                + "Read the recent end of the log before acting.")
        if let reportsDirectory {
            paragraphs.append(
                "Recent reports are available under:\n\(reportsDirectory)\n"
                + "Read the recent reports before acting.")
        }
        paragraphs.append(
            "Any text following this handoff context is the user's current instruction.\n"
            + closing)
        return paragraphs.joined(separator: "\n\n")
    }

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
        if let end = message.range(of: closing) {
            instruction = message[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Continuation(sourceName: name, sourceSessionId: String(id), instruction: instruction)
    }
}
