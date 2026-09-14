import Foundation

/// The user half of the summary prompt, as data both languages read.
///
/// The system half is one string and moved to the contract directory easily.
/// This half is conditional, and the temptation was to write it twice: once in
/// Swift, once in the Gateway's TypeScript. Two implementations of the same
/// conditionals agree on the day they are written and then drift in silence,
/// which is exactly how a folder of replay prompts came to be evaluating
/// something that had not shipped for months.
///
/// So it is ordered segments with a closed vocabulary of conditions. There is
/// deliberately no template language: a mini-language is one more thing two
/// implementations can disagree about, and "append this text when that field is
/// present" needs none.
public struct UserPromptTemplate: Sendable {

    public struct Segment: Sendable, Decodable {
        public let when: String
        public let text: String
    }

    public let defaults: [String: String]
    public let segments: [Segment]

    private struct Document: Decodable {
        let defaults: [String: String]
        let segments: [Segment]
    }

    public init(json: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: json)
        self.defaults = document.defaults
        self.segments = document.segments
    }

    /// The contract's copy, loaded once.
    ///
    /// Read from the repository. Bundling it into the .app comes with the
    /// switch-over, not before.
    public static let shared: UserPromptTemplate = {
        for url in candidateURLs() {
            if let data = try? Data(contentsOf: url),
               let template = try? UserPromptTemplate(json: data) {
                return template
            }
        }
        // An empty template renders an empty prompt, which fails loudly in a
        // test rather than quietly shipping a summary with no content.
        return UserPromptTemplate(defaults: [:], segments: [])
    }()

    init(defaults: [String: String], segments: [Segment]) {
        self.defaults = defaults; self.segments = segments
    }

    private static func candidateURLs() -> [URL] {
        // Walking up from this source file finds the contract directory in a
        // checkout, which is what the tests and the replay harness use.
        //
        // No bundle lookup yet, deliberately. Declaring the file as a SwiftPM
        // resource is the step that makes this usable from the shipped .app,
        // and it is not needed until the shipped path switches over, which it
        // does not until the test below proves the two renderers agree.
        var urls: [URL] = []
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            urls.append(dir.appendingPathComponent(
                "contracts/gateway/v1/summary-user-template.json"))
            dir = dir.deletingLastPathComponent()
        }
        return urls
    }

    public func render(for request: SummaryRequest) -> String {
        var out = ""
        for segment in segments where holds(segment.when, request) {
            out += substitute(segment.text, request)
        }
        return out
    }

    /// The closed vocabulary. A condition is presence, and for the carried goal
    /// it is presence AND non-emptiness, because an empty goal is not a goal and
    /// a presence-only check would emit the block with nothing under it.
    private func holds(_ condition: String, _ r: SummaryRequest) -> Bool {
        switch condition {
        case "always": return true
        case "notification": return r.hookEvent == .notification
        case "git_branch": return r.gitBranch != nil
        case "previous_goal": return !(r.previousGoal ?? "").isEmpty
        case "first_user_message": return r.firstUserMessage != nil
        case "corrective_note": return r.correctiveNote != nil
        default: return false
        }
    }

    private func substitute(_ text: String, _ r: SummaryRequest) -> String {
        var out = text
        let values: [String: String] = [
            "project_label": r.projectLabel,
            "notification_matcher": r.notificationMatcher
                ?? defaults["notification_matcher"] ?? "",
            "git_branch": r.gitBranch ?? "",
            "previous_goal": r.previousGoal ?? "",
            "first_user_message": r.firstUserMessage ?? "",
            "last_assistant_message": r.lastAssistantMessage,
            "corrective_note": r.correctiveNote ?? "",
        ]
        // Replacement, never a format function: the prompt contains JSON braces
        // and a formatter would treat them as slots of its own.
        for (slot, value) in values {
            out = out.replacingOccurrences(of: "{\(slot)}", with: value)
        }
        return out
    }
}
