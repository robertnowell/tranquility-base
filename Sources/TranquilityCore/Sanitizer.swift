import Foundation

/// One piece of a spoken line, in both of the forms it exists in.
///
/// A verbatim piece reads and speaks identically. A redacted piece reads as the
/// thing the session actually named (`dispatchAttempts`) and speaks as the
/// category (`a variable`), because the eye wants the name and the ear cannot
/// use it.
///
/// This is the whole trick: there are not two strings to keep in step. There is
/// one sequence, and the spoken and displayed forms are both projections of it,
/// so they cannot drift apart.
public struct SpokenSegment: Sendable, Equatable {
    /// What the reader sees.
    public let display: String
    /// What the voice says. Equal to `display` for verbatim pieces.
    public let spoken: String
    /// The rule that rewrote this piece; nil when nothing was rewritten.
    public let label: String?

    public var isRedacted: Bool { label != nil }

    fileprivate init(display: String, spoken: String, label: String?) {
        self.display = display
        self.spoken = spoken
        self.label = label
    }

    fileprivate static func verbatim(_ text: String) -> SpokenSegment {
        SpokenSegment(display: text, spoken: text, label: nil)
    }
}

/// Text that is safe to speak aloud, carrying the unredacted form alongside it.
///
/// The only way to make one is through `SpokenTextSanitizer`. That is the point:
/// `SpeechProvider.speak` accepts nothing else, so no future code path can hand raw
/// model output to text-to-speech by accident. A prompt instruction alone erodes —
/// the model eventually slips a commit hash through and the loop reads it out.
///
/// `text` is what is spoken. `displayText` is what the panel shows. They are built
/// together from `segments` in one pass, which is what makes
/// `displayIndex(forSpoken:)` exact rather than an estimate.
public struct SanitizedSpokenText: Sendable, Equatable {
    /// The spoken projection, clamped to the word budget.
    public let text: String
    /// The unredacted projection — every name the session actually used. Never
    /// clamped: the eye can read past where the voice stopped.
    public let displayText: String
    /// The pieces, in order.
    public let segments: [SpokenSegment]
    public let wordCount: Int
    /// What the sanitizer had to replace, as rule labels. Useful for tests and for
    /// telling whether the summarizer is behaving.
    public let redactions: [String]
    /// The budget this text was clamped against. Carried so that a later edit —
    /// prepending a callsign, stripping a label echo — rebuilds against the same
    /// budget instead of silently reverting to the default.
    public let budget: Int

    /// Where each segment landed in `text` and in `displayText`. Same count as
    /// `segments`; parallel by construction, never recomputed by arithmetic.
    private let spokenRanges: [Range<Int>]
    private let displayRanges: [Range<Int>]

    fileprivate init(segments: [SpokenSegment], maxWords: Int) {
        let spoken = SanitizedSpokenText.project(segments, \.spoken)
        let display = SanitizedSpokenText.project(segments, \.display)
        let clamped = SpokenTextSanitizer.clamp(spoken.text, maxWords: maxWords)

        self.segments = segments
        self.text = clamped
        self.displayText = display.text
        self.spokenRanges = spoken.ranges
        self.displayRanges = display.ranges
        self.wordCount = clamped.split(whereSeparator: \.isWhitespace).count
        self.redactions = segments.compactMap(\.label)
        self.budget = maxWords
    }

    /// Translate a cursor in the spoken text to the matching cursor in the
    /// displayed text — this is what keeps the highlight honest when the two
    /// differ.
    ///
    /// Inside a verbatim segment the two strings are character-identical, so the
    /// mapping is exact. Inside a redacted one it is atomic: the moment the voice
    /// starts saying "a variable", the whole of `dispatchAttempts` lights up,
    /// because an entity is one thing to a reader even when it is three words to
    /// a listener.
    public func displayIndex(forSpoken index: Int) -> Int {
        guard !segments.isEmpty else { return 0 }
        // The cursor can never lead the voice past what the voice will actually
        // say: the clamp may have dropped a tail that is still on screen.
        let cursor = min(max(index, 0), text.count)
        guard cursor > 0 else { return 0 }

        for (i, range) in spokenRanges.enumerated() {
            guard cursor < range.upperBound else { continue }
            let display = displayRanges[i]
            guard segments[i].isRedacted else {
                return min(display.lowerBound + (cursor - range.lowerBound), display.upperBound)
            }
            // Atomic: nothing of the name is lit until its stand-in has begun,
            // and then all of it is.
            return cursor <= range.lowerBound ? display.lowerBound : display.upperBound
        }
        return displayRanges.last?.upperBound ?? 0
    }

    /// Where the spoken text ran out, in display coordinates. Everything after
    /// this was written and shown but never said — the clamp dropped it.
    public var spokenTailBegins: Int { displayIndex(forSpoken: text.count) }

    /// Concatenate the segment texts, normalising whitespace as it goes and
    /// recording where each segment landed.
    ///
    /// The normalisation is inline rather than a regex pass afterwards, and that
    /// is deliberate: a post-hoc `\s+` collapse would shift every offset after it
    /// and put us back to maintaining a map by arithmetic. Building the string and
    /// its index at the same time means there is nothing to keep in step.
    private static func project(
        _ segments: [SpokenSegment], _ key: KeyPath<SpokenSegment, String>
    ) -> (text: String, ranges: [Range<Int>]) {
        var out: [Character] = []
        var ranges: [Range<Int>] = []

        for segment in segments {
            var start = out.count
            let characters = Array(segment[keyPath: key])
            for (i, character) in characters.enumerated() {
                if character.isWhitespace {
                    // Collapse runs, and never open with one.
                    guard let last = out.last, !last.isWhitespace else { continue }
                    out.append(" ")
                } else {
                    // " ," → ","  — the gap a replacement leaves behind. Only when
                    // the mark ends a clause: in "tranquilitybase.dev and .sh" the
                    // dot opens a word, and closing that gap would weld it to the
                    // word before it.
                    let next = i + 1 < characters.count ? characters[i + 1] : nil
                    let opensAWord = next?.isLetter == true || next?.isNumber == true
                    if character.isPunctuationForSpeech, !opensAWord, out.last == " " {
                        out.removeLast()
                        start = min(start, out.count)
                        if var previous = ranges.last, previous.upperBound > out.count {
                            previous = previous.lowerBound..<max(previous.lowerBound, out.count)
                            ranges[ranges.count - 1] = previous
                        }
                    }
                    out.append(character)
                }
            }
            ranges.append(min(start, out.count)..<out.count)
        }

        while out.last?.isWhitespace == true {
            out.removeLast()
            for (i, range) in ranges.enumerated() where range.upperBound > out.count {
                ranges[i] = min(range.lowerBound, out.count)..<out.count
            }
        }
        return (String(out), ranges)
    }
}

private extension Character {
    var isPunctuationForSpeech: Bool { ".,;:!?".contains(self) }
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
        /// What the rewrite means for the reader.
        enum Kind {
            /// The name is worth reading even though it cannot be spoken, so the
            /// display keeps it and only the speech is genericised.
            case redaction
            /// Layout that exists only on a page. Neither form wants it, so both
            /// projections take the cleaned text.
            case formatting
        }
        let pattern: String
        let replacement: String
        let label: String
        var kind: Kind = .redaction
    }

    // Order matters: code spans and URLs first, so their innards aren't matched
    // piecemeal by the narrower rules underneath. Order is enforced by first
    // claim wins — an earlier rule's span is not offered to a later one.
    private static let rules: [Rule] = [
        .init(pattern: "```[\\s\\S]*?```", replacement: "some code", label: "code-block"),
        .init(pattern: "`[^`]+`", replacement: "some code", label: "code-span"),
        // Markdown is written to be looked at, not heard. A real corpus run over
        // archived sessions read table pipes and header hashes aloud, which is
        // unusable — so structure is stripped before anything else is considered.
        .init(pattern: "(?:\\|[^|]*){2,}\\|", replacement: "a table", label: "table"),
        .init(pattern: "(?:^|\\s)#{1,6}\\s+", replacement: " ", label: "heading", kind: .formatting),
        .init(pattern: "\\*\\*([^*]+)\\*\\*", replacement: "$1", label: "bold", kind: .formatting),
        .init(pattern: "(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])", replacement: "$1", label: "italic",
              kind: .formatting),
        .init(pattern: "\\[([^\\]]+)\\]\\([^)]*\\)", replacement: "$1", label: "md-link",
              kind: .formatting),
        .init(pattern: "(?:^|\\s)[-–—]{3,}(?=\\s|$)", replacement: " ", label: "rule",
              kind: .formatting),
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

    /// Rules that genericize identifier-shaped tokens and may therefore consult
    /// the allowlist. Structural rules (paths, hashes, UUIDs, URLs, filenames,
    /// markdown) never do: a path is a path even when the source names it.
    private static let allowlistAwareLabels: Set<String> = ["symbol", "opaque-token"]

    /// Phrases dense enough to become noise when they repeat. A message naming
    /// four columns would otherwise speak "a variable a variable a variable a
    /// variable", which is worse than saying it once — while the DISPLAY keeps
    /// all four names, which is the entire point of the split.
    private static let collapsiblePhrases: Set<String> = [
        "some code", "a file path", "a file", "a table", "an identifier", "a commit", "a link",
        "a variable",
    ]

    /// `allowing` is the speakable-names allowlist (see `speakableTerms(in:)`):
    /// tokens the SOURCE itself used as names — "say Klaviyo, not 'an email
    /// platform'". Only the identifier-genericizing rules consult it; when a
    /// token is not on the list, the existing stripping behavior stands.
    public func sanitize(
        _ raw: String, maxWords: Int = SpokenTextSanitizer.maxWords,
        allowing allowlist: Set<String> = []
    ) -> SanitizedSpokenText {
        let working = raw.replacingOccurrences(of: "\n", with: " ")
        let segments = Self.collapsingRepeats(Self.segments(of: working, allowing: allowlist))
        return SanitizedSpokenText(segments: segments, maxWords: maxWords)
    }

    /// Cut the text into verbatim and redacted pieces.
    ///
    /// Every rule matches against the ORIGINAL text and claims spans; a span that
    /// overlaps one already claimed is dropped. That is what preserves the old
    /// sequential behaviour — a code span claims its whole range first, so the
    /// narrower rules never get to pick at its innards — without ever rewriting
    /// the string underneath the rules, which is what made the offsets unknowable.
    private static func segments(of working: String, allowing allowlist: Set<String>) -> [SpokenSegment] {
        struct Claim {
            let range: Range<String.Index>
            let label: String
            let spoken: String
            let kind: Rule.Kind
        }
        var claims: [Claim] = []

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let consultsAllowlist = !allowlist.isEmpty && allowlistAwareLabels.contains(rule.label)
            let full = NSRange(working.startIndex..., in: working)
            for match in regex.matches(in: working, range: full) {
                guard let range = Range(match.range, in: working), !range.isEmpty else { continue }
                guard !claims.contains(where: { $0.range.overlaps(range) }) else { continue }
                if consultsAllowlist, allowlist.contains(String(working[range])) { continue }
                let spoken = rule.kind == .formatting
                    ? regex.replacementString(for: match, in: working, offset: 0,
                                              template: rule.replacement)
                    : rule.replacement
                claims.append(Claim(range: range, label: rule.label, spoken: spoken, kind: rule.kind))
            }
        }
        claims.sort { $0.range.lowerBound < $1.range.lowerBound }

        var out: [SpokenSegment] = []
        var cursor = working.startIndex
        for claim in claims {
            if cursor < claim.range.lowerBound {
                out.append(.verbatim(String(working[cursor..<claim.range.lowerBound])))
            }
            let shown = claim.kind == .formatting ? claim.spoken : String(working[claim.range])
            out.append(SpokenSegment(display: shown, spoken: claim.spoken, label: claim.label))
            cursor = claim.range.upperBound
        }
        if cursor < working.endIndex { out.append(.verbatim(String(working[cursor...]))) }
        return out
    }

    /// Silence a run of identical replacements, keeping the first.
    ///
    /// "a variable, a variable, a variable" is unusable as speech. Only the SPOKEN
    /// side is emptied — every display name survives, so the reader still sees all
    /// four column names while the listener hears the phrase once.
    private static func collapsingRepeats(_ segments: [SpokenSegment]) -> [SpokenSegment] {
        var out = segments
        var index = 0
        while index < out.count {
            guard let label = out[index].label, collapsiblePhrases.contains(out[index].spoken) else {
                index += 1; continue
            }
            let phrase = out[index].spoken
            // Scan forward over separator-only verbatim pieces looking for the
            // same phrase again.
            var scan = index + 1
            var lastRepeat = index
            while scan < out.count {
                let segment = out[scan]
                if segment.label == nil {
                    if segment.spoken.allSatisfy({ $0.isWhitespace || ",;:()-".contains($0) }) {
                        scan += 1; continue
                    }
                    break
                }
                if segment.spoken == phrase { lastRepeat = scan; scan += 1; continue }
                break
            }
            if lastRepeat > index {
                for i in (index + 1)...lastRepeat {
                    out[i] = SpokenSegment(display: out[i].display, spoken: "", label: out[i].label)
                }
                _ = label
            }
            index = max(lastRepeat, index) + 1
        }
        return out
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

    // MARK: - Speakable names (the allowlist)

    /// Product tokens whose casing makes them look like camelCase identifiers to
    /// the symbol rule. Deliberately tiny: a name earns a place here by being a
    /// word a person says aloud, and anything ambiguous stays OFF the list —
    /// when unsure whether a token is an identifier, the stripping behavior wins.
    static let knownProductTokens: Set<String> = [
        "iPhone", "iPad", "iMac", "iPod", "iOS", "iPadOS", "macOS", "watchOS",
        "tvOS", "visionOS", "iCloud", "iMessage", "iTerm", "iTerm2", "eBay",
        "jQuery", "npm",
    ]

    /// Names the SOURCE message itself used, and which are therefore speakable:
    /// capitalized simple words ("Klaviyo", "Slack") and known product tokens
    /// ("iPhone"). A capitalized word with interior capitals ("GitHubActions",
    /// "BuildLockedLayoutAssets") is identifier-shaped and stays out; so does
    /// anything with underscores, digits-only content, or opaque length. The
    /// list only ever EXEMPTS a token from the identifier rules — it never makes
    /// a path, hash, or filename speakable.
    public static func speakableTerms(in source: String) -> Set<String> {
        var out = Set<String>()
        let tokens = source.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for raw in tokens {
            let word = String(raw)
            guard word.count >= 2, word.count <= 20 else { continue }
            if knownProductTokens.contains(word) {
                out.insert(word)
                continue
            }
            guard let first = word.first, first.isUppercase else { continue }
            // One initial capital and nothing else uppercase: "Klaviyo" yes,
            // "GitHub"/"BuildLocked" no — conservative by design.
            guard word.dropFirst().allSatisfy({ !$0.isUppercase }) else { continue }
            out.insert(word)
        }
        return out
    }

    // MARK: - Mechanical callsign prefix

    /// Attribution is never delegated to the model (measured compliance 65/71,
    /// and the miss is brand-substitution — a promotions session opening
    /// "Kopi:"). Strip whatever label-like prefix the model wrote — the project
    /// label, the live session name, or the callsign itself — then prepend the
    /// minted callsign exactly once. "promotions: promotions:" is impossible by
    /// construction. Lives here because only this file can mint a
    /// `SanitizedSpokenText`, which is the type's whole point.
    ///
    /// The callsign joins as a segment, so it is spoken AND shown, and every
    /// other segment's index moves with it automatically.
    public func applyingCallsign(
        _ callsign: String, strippingLabels labels: [String], to spoken: SanitizedSpokenText
    ) -> SanitizedSpokenText {
        let stripped = Self.strippingLeadingLabels(labels + [callsign], from: spoken.segments)
        let prefix = SpokenSegment.verbatim(
            Self.isEmpty(stripped) ? "\(callsign):" : "\(callsign): ")
        return SanitizedSpokenText(segments: [prefix] + stripped, maxWords: spoken.budget)
    }

    /// Strip a leading callsign/label echo WITHOUT prepending one.
    ///
    /// Depth-1 speaks inside an established exchange — the same agent that just
    /// finished talking — so a callsign there is redundancy, not attribution
    /// (ruled 05 Aug). The strip still matters: the model sometimes opens the
    /// field with the callsign anyway, and hearing it once is the contract.
    public func strippingLeadingLabels(
        _ labels: [String], from spoken: SanitizedSpokenText
    ) -> SanitizedSpokenText {
        let stripped = Self.strippingLeadingLabels(labels, from: spoken.segments)
        guard !Self.isEmpty(stripped) else { return spoken }
        return SanitizedSpokenText(segments: stripped, maxWords: spoken.budget)
    }

    private static func isEmpty(_ segments: [SpokenSegment]) -> Bool {
        segments.allSatisfy { $0.spoken.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The label echo only ever sits at the very front, which is inside the first
    /// verbatim segment — so this is a string edit on one segment, not a reflow.
    private static func strippingLeadingLabels(
        _ labels: [String], from segments: [SpokenSegment]
    ) -> [SpokenSegment] {
        guard let first = segments.first, !first.isRedacted else { return segments }
        let stripped = Callsign.strippingLabelPrefixes(first.display, labels: labels)
        guard stripped != first.display else { return segments }
        var out = segments
        if stripped.isEmpty {
            out.removeFirst()
        } else {
            out[0] = .verbatim(stripped)
        }
        return out
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
