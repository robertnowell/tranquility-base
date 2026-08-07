import Foundation

/// Open issue #9: the summary once spoke "three of five checks passed" when the
/// source said no such counts. A number is the most confident-sounding thing a
/// voice can say, and a listener cannot check it — so any digit token in the
/// spoken sections that the source never said is treated as invented.
///
/// Deterministic on purpose. The pool is built generously (every digit run, every
/// spelled number one..ninety-nine, from the final message AND the context blocks)
/// so that a genuinely grounded number is never flagged; the cost of a false
/// positive is a lost clause, so the bias runs the other way.
public enum DigitGrounding {
    /// Digit tokens: runs of digits, optionally with `.` or `,` separators
    /// ("1,234", "3.14"). Normalized by stripping commas.
    static let tokenPattern = "\\d+(?:[.,]\\d+)*"

    // MARK: - Source pool

    /// Every number the source can be said to have stated: the agent's final
    /// message plus the notification/opening context blocks (and the project
    /// label, whose digits — "m3-tracker" — are legitimately speakable).
    public static func sourcePool(for request: SummaryRequest) -> Set<String> {
        var text = request.lastAssistantMessage
        if let opening = request.firstUserMessage { text += " " + opening }
        if let matcher = request.notificationMatcher { text += " " + matcher }
        text += " " + request.projectLabel
        return pool(from: text)
    }

    static func pool(from text: String) -> Set<String> {
        var out = Set<String>()
        for token in matches(of: tokenPattern, in: text) {
            out.insert(normalize(token))
            // Sub-runs too ("3.14" also grounds "3" and "14"): a generous pool
            // means fewer false positives, which is the conservative direction.
            for run in matches(of: "\\d+", in: token) { out.insert(run) }
        }
        for (word, value) in spelledNumbers {
            if text.range(of: "\\b\(word)\\b",
                          options: [.regularExpression, .caseInsensitive]) != nil {
                out.insert(String(value))
            }
        }
        return out
    }

    /// one..ninety-nine, including hyphenated and spaced compounds
    /// ("twenty-one", "twenty one").
    static let spelledNumbers: [(String, Int)] = {
        let ones = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                    "six": 6, "seven": 7, "eight": 8, "nine": 9]
        let teens = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
                     "fourteen": 14, "fifteen": 15, "sixteen": 16,
                     "seventeen": 17, "eighteen": 18, "nineteen": 19]
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
                    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        var out: [(String, Int)] = []
        out.append(contentsOf: ones.map { ($0.key, $0.value) })
        out.append(contentsOf: teens.map { ($0.key, $0.value) })
        out.append(contentsOf: tens.map { ($0.key, $0.value) })
        for (tenWord, tenValue) in tens {
            for (oneWord, oneValue) in ones {
                out.append(("\(tenWord)-\(oneWord)", tenValue + oneValue))
                out.append(("\(tenWord) \(oneWord)", tenValue + oneValue))
            }
        }
        return out
    }()

    // MARK: - Detection

    /// Digit tokens in the SPOKEN sections (recap + proposal) absent from the pool,
    /// in order of appearance, deduplicated.
    public static func ungroundedTokens(in brief: SessionBrief, pool: Set<String>) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for text in [brief.recap, brief.proposal].compactMap({ $0 }) {
            for token in matches(of: tokenPattern, in: text) {
                let normalized = normalize(token)
                guard !pool.contains(normalized), seen.insert(normalized).inserted else { continue }
                out.append(normalized)
            }
        }
        return out
    }

    // MARK: - Scrubbing

    /// Remove the minimal clause carrying each offending token. Conservative:
    /// whole clauses (between , ; : and sentence bounds) go, never partial words;
    /// a final literal pass guarantees the number itself is never spoken even if
    /// clause splitting misses. Never crashes, never returns the token.
    public static func scrub(_ brief: SessionBrief, tokens: Set<String>) -> SessionBrief {
        var out = brief
        out.recap = out.recap.map { scrubText($0, tokens: tokens) }
        out.proposal = out.proposal.map { scrubText($0, tokens: tokens) }
        if out.recap?.isEmpty == true { out.recap = nil }
        if out.proposal?.isEmpty == true { out.proposal = nil }
        // If scrubbing emptied the recap, spokenText() falls back to assembling
        // from the card fields — so those must not smuggle the number back in.
        if out.recap == nil {
            out.happened = scrubText(out.happened, tokens: tokens)
            out.nextStep = out.nextStep.map { scrubText($0, tokens: tokens) }
            out.question = out.question.map { scrubText($0, tokens: tokens) }
            if out.happened.isEmpty { out.happened = "finished a turn" }
        }
        return out
    }

    static func scrubText(_ text: String, tokens: Set<String>) -> String {
        var keptSentences: [String] = []
        for sentence in SpokenTextSanitizer.sentences(in: text) {
            let clauses = sentence.components(separatedBy: CharacterSet(charactersIn: ",;:"))
            let kept = clauses.filter { !containsAny(tokens, in: $0) }
            if kept.count == clauses.count {
                keptSentences.append(sentence)          // untouched
            } else if kept.isEmpty {
                continue                                // whole sentence goes
            } else {
                var rebuilt = kept
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                if let last = sentence.last, ".!?".contains(last), !rebuilt.hasSuffix(String(last)) {
                    rebuilt += String(last)
                }
                keptSentences.append(rebuilt)
            }
        }
        var result = keptSentences.joined(separator: " ")
        // Belt and braces: the number itself must never survive.
        for token in matches(of: tokenPattern, in: result)
        where tokens.contains(normalize(token)) {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsAny(_ tokens: Set<String>, in clause: String) -> Bool {
        matches(of: tokenPattern, in: clause).contains { tokens.contains(normalize($0)) }
    }

    // MARK: - Plumbing

    static func normalize(_ token: String) -> String {
        token.replacingOccurrences(of: ",", with: "")
    }

    static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
