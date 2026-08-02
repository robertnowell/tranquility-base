import Foundation

/// Text that is safe to speak aloud.
///
/// The only way to make one is through `SpokenTextSanitizer`. That is the point:
/// `SpeechProvider.speak` accepts nothing else, so no future code path can hand raw
/// model output to text-to-speech by accident. A prompt instruction alone erodes —
/// the model eventually slips a commit hash through and the loop reads it out.
public struct SanitizedSpokenText: Sendable, Equatable {
    public let text: String
    public let wordCount: Int
    /// What the sanitizer had to replace. Useful for tests and for telling whether
    /// the summarizer is behaving.
    public let redactions: [String]

    fileprivate init(text: String, redactions: [String]) {
        self.text = text
        self.wordCount = text.split(whereSeparator: \.isWhitespace).count
        self.redactions = redactions
    }
}

public struct SpokenTextSanitizer: Sendable {
    /// Spoken summaries are budgeted in seconds, not words. Measured with `say`:
    /// 25 words ≈ 9.9s, 42 words ≈ 16.3s, 81 words ≈ 29.0s. 35 words is ~13s, which
    /// is about as long as an unsolicited interruption can reasonably be.
    public static let maxWords = 35

    public init() {}

    private struct Rule {
        let pattern: String
        let replacement: String
        let label: String
    }

    // Order matters: code spans and URLs first, so their innards aren't matched
    // piecemeal by the narrower rules underneath.
    private static let rules: [Rule] = [
        .init(pattern: "```[\\s\\S]*?```", replacement: "some code", label: "code-block"),
        .init(pattern: "`[^`]+`", replacement: "some code", label: "code-span"),
        // Markdown is written to be looked at, not heard. A real corpus run over
        // archived sessions read table pipes and header hashes aloud, which is
        // unusable — so structure is stripped before anything else is considered.
        .init(pattern: "(?:\\|[^|]*){2,}\\|", replacement: "a table", label: "table"),
        .init(pattern: "(?:^|\\s)#{1,6}\\s+", replacement: " ", label: "heading"),
        .init(pattern: "\\*\\*([^*]+)\\*\\*", replacement: "$1", label: "bold"),
        .init(pattern: "(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])", replacement: "$1", label: "italic"),
        .init(pattern: "\\[([^\\]]+)\\]\\([^)]*\\)", replacement: "$1", label: "md-link"),
        .init(pattern: "(?:^|\\s)[-–—]{3,}(?=\\s|$)", replacement: " ", label: "rule"),
        .init(pattern: "https?://[^\\s]+", replacement: "a link", label: "url"),
        .init(
            pattern: "\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b",
            replacement: "an identifier", label: "uuid"),
        // A hex hash must contain a digit, otherwise ordinary words made only of
        // a-f letters ("accede", "defaced") get mangled.
        .init(
            pattern: "\\b(?=[0-9a-f]{7,40}\\b)(?=[a-f]*[0-9])[0-9a-f]{7,40}\\b",
            replacement: "a commit", label: "hash"),
        .init(pattern: "(?:~|\\.{1,2})?/[\\w.\\-]+(?:/[\\w.\\-]+)+/?", replacement: "a file path", label: "path"),
        // Filenames, optionally with a relative directory prefix, so `lib/format.swift`
        // is consumed whole rather than leaving a dangling `lib/format`.
        .init(
            pattern: "\\b(?:[\\w.\\-]+/)*[\\w\\-]+\\.(?:swift|ts|tsx|js|jsx|py|rb|go|rs|java|kt|c|h|cpp|json|ya?ml|toml|md|sh|sql|html|css)\\b",
            replacement: "a file", label: "filename"),
        // Long opaque tokens: session ids, keys, base64-ish blobs.
        .init(pattern: "\\b[A-Za-z0-9_\\-]{24,}\\b", replacement: "an identifier", label: "opaque-token"),
    ]

    public func sanitize(_ raw: String) -> SanitizedSpokenText {
        var working = raw.replacingOccurrences(of: "\n", with: " ")
        var redactions: [String] = []

        for rule in Self.rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(working.startIndex..., in: working)
            let hits = regex.numberOfMatches(in: working, range: range)
            if hits > 0 {
                redactions.append(contentsOf: Array(repeating: rule.label, count: hits))
                working = regex.stringByReplacingMatches(
                    in: working, range: range, withTemplate: rule.replacement)
            }
        }

        // A message dense with code spans collapses to "some code some code some
        // code", which is worse than saying it once.
        for phrase in ["some code", "a file path", "a file", "a table", "an identifier", "a commit", "a link"] {
            let repeated = "(?:\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b[\\s,;:()\\-]*){2,}"
            working = working.replacingOccurrences(
                of: repeated, with: "\(phrase) ", options: .regularExpression)
        }

        working = working
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([.,;:!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SanitizedSpokenText(text: Self.clamp(working), redactions: redactions)
    }

    /// Trim to the word budget, preferring a sentence boundary so the speech doesn't
    /// stop mid-clause.
    static func clamp(_ text: String, maxWords: Int = maxWords) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > maxWords else { return text }

        let head = words.prefix(maxWords).joined(separator: " ")
        if let lastStop = head.lastIndex(where: { ".!?".contains($0) }) {
            let upTo = head[...lastStop]
            // Only honour the sentence break if it keeps most of the budget.
            if upTo.split(separator: " ").count >= maxWords / 2 {
                return String(upTo)
            }
        }
        return head + "…"
    }
}
