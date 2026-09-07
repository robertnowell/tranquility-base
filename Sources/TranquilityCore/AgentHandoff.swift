import Foundation

/// The small pure part of continuing one live agent's work in another harness.
/// Launching remains the app's ordinary New Agent path; this type only answers
/// which of today's two harnesses is the destination and what context rides the
/// destination's first explicit user message.
public enum AgentHandoff {
    public struct Destination: Equatable, Sendable {
        public let harness: String
        public let label: String

        public init(harness: String, label: String) {
            self.harness = harness
            self.label = label
        }
    }

    public static func destination(for sourceHarness: String?) -> Destination? {
        switch sourceHarness {
        case ClaudeCodeAdapter().id:
            return Destination(harness: CodexAdapter().id, label: "Codex")
        case CodexAdapter().id:
            return Destination(harness: ClaudeCodeAdapter().id, label: "Claude Code")
        default:
            return nil
        }
    }

    public static func sourceLabel(for harness: String) -> String {
        harness == CodexAdapter().id ? "Codex" : "Claude Code"
    }

    /// A message fragment, not a command and not a second kind of launch.
    /// `reportsDirectory` is present only after the caller verified that the
    /// source session actually has a hub on disk.
    public static func fragment(
        sourceName: String,
        sourceHarness: String,
        sourceSessionId: String,
        logLocation: String,
        reportsDirectory: String?
    ) -> String {
        var paragraphs = [
            "Please continue the work of \u{201C}\(sourceName)\u{201D} "
                + "(\(sourceLabel(for: sourceHarness)), session \(sourceSessionId)).",
            "Local session logs can be found at:\n\(logLocation)\n"
                + "Read the recent end of the log before acting.",
        ]
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
