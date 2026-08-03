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
    /// Budgeted in seconds, not words. Measured with `say -r 200`: 39 words = 16.5s,
    /// so roughly 0.42s per word.
    ///
    /// 70 words is the deliberate target: Claude Code's own session recap (under 40
    /// words — goal, current task, next action) followed by ~30 more covering the key
    /// result, the next step, and any decision or risk. That is about thirty seconds.
    /// Longer than a notification, shorter than opening the tab and reading.
    public static let maxWords = 75
    /// Section one — Claude Code's recap instruction is "under 40 words".
    public static let recapWords = 40
    /// Section two — the proposal, the decision, and the risk that would change
    /// your answer.
    ///
    /// 40 rather than the 30 originally specified. At 30 the risk was being clamped
    /// mid-clause ("…a queue may be simpler and sidestep…"), and half a warning is
    /// worse than no warning: it is exactly the "approved something I later
    /// regretted" failure the section exists to prevent. Three things — action,
    /// decision, risk — do not fit in thirty words when the risk is substantive.
    public static let proposalWords = 40

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
        // camelCase and snake_case symbol names. English doesn't camelCase, so this
        // is safe — and it is the rule that was missing when `availableBrandAssets`
        // and `buildLockedLayoutAssets` were read aloud verbatim.
        .init(pattern: "\\b[a-z]+(?:[A-Z][a-zA-Z0-9]*){1,}\\b", replacement: "a variable", label: "symbol"),
        .init(pattern: "\\b[a-z][a-z0-9]*(?:_[a-z0-9]+){1,}\\b", replacement: "a variable", label: "symbol"),
    ]

    public func sanitize(_ raw: String, maxWords: Int = SpokenTextSanitizer.maxWords) -> SanitizedSpokenText {
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

        return SanitizedSpokenText(text: Self.clamp(working, maxWords: maxWords), redactions: redactions)
    }

    /// Trim to the word budget WITHOUT ever cutting mid-clause.
    ///
    /// Speech is not text you can re-read. A clipped sentence — "…a queue may be
    /// simpler and sidestep…" — is worse than saying nothing, because the listener
    /// hears half a warning and has no way to recover the rest. So this drops whole
    /// sentences and never appends an ellipsis. If even the first sentence exceeds
    /// the budget it is spoken in full: a slightly long complete thought beats a
    /// correctly-sized fragment.
    ///
    /// The budget is therefore a target for the model, and this is a safety net that
    /// should rarely fire — not a formatter.
    static func clamp(_ text: String, maxWords: Int = maxWords) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.split(separator: " ", omittingEmptySubsequences: true).count > maxWords,
              !trimmed.isEmpty
        else { return trimmed }

        var kept: [String] = []
        var total = 0
        for sentence in sentences(in: trimmed) {
            let count = sentence.split(separator: " ", omittingEmptySubsequences: true).count
            if !kept.isEmpty, total + count > maxWords { break }
            kept.append(sentence)
            total += count
            // First sentence is always kept, even if it alone blows the budget.
            if total >= maxWords { break }
        }
        return kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split on sentence-ending punctuation followed by whitespace, keeping the
    /// punctuation attached.
    static func sentences(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?<=[.!?])\\s+") else { return [text] }
        var out: [String] = []
        var cursor = text.startIndex
        let full = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            out.append(String(text[cursor..<range.lowerBound]))
            cursor = range.upperBound
        }
        if cursor < text.endIndex { out.append(String(text[cursor...])) }
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
