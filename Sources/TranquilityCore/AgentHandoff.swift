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
        public var id: String { harness }

        public init(harness: String, label: String) {
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
            .map { Destination(harness: $0.id, label: $0.name) }
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
            "Please continue the work of \u{201C}\(sourceName)\u{201D} "
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
            + "Propose a path forward after understanding the current state.")
        return paragraphs.joined(separator: "\n\n")
    }
}
