import Foundation

/// Two — at worst three — plain spoken words that name a session for its whole
/// life: "promotions copy". Never hyphenated (ruled 06 Aug): callsigns exist to
/// be SAID, and TTS mangles joined compounds ("facts-cache" garbled on every
/// announcement) while plain dictionary words survive.
///
/// The tuned prompt asks the model to open the recap with the project label, and
/// it complies 65/71 — but the failure class is brand-substitution: a promotions
/// session opening "Kopi:" because the CONTENT was about Kopi. Attribution is too
/// important to delegate to a model, so the spoken prefix is minted here,
/// deterministically, and prepended mechanically at announce time. 100% by
/// construction.
///
/// Minted ONCE at the session's first successful summary and frozen thereafter
/// (stored in GRDB): a name that drifts turn-to-turn is not a name.
public enum Callsign {

    // MARK: - Directory word

    /// The leading word(s): where the session lives. Mirrors `StatusHUD.identify`'s
    /// worktree handling — worktrees nest the real name under
    /// `.claude/worktrees/<name>/<project>`, so the last component alone is
    /// ambiguous; the component after the plumbing is the one the user named.
    ///
    /// Folder names are written for filesystems; callsigns are written for a
    /// voice. TTS mangles joined compounds — "facts-cache" came out garbled on
    /// every announcement (ruled 06 Aug; the research classes that fail are
    /// coined compounds, cluster-final words, homographs — plain dictionary
    /// words survive). So the folder name is split into its plain words, and a
    /// long name keeps its last two — the tail of a kebab-case name is where
    /// the specific part lives ("agent-interface-layer" → "interface layer").
    public static func directoryWord(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "session" }
        let home = NSHomeDirectory()
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if trimmed == home || trimmed == "~" { return "home" }

        let parts = URL(fileURLWithPath: cwd).pathComponents.filter { $0 != "/" }
        let raw: String
        if let marker = parts.firstIndex(of: "worktrees"), marker + 1 < parts.count {
            raw = parts[marker + 1]
        } else {
            raw = parts.last ?? "session"
        }
        let words = raw.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return "session" }
        return words.suffix(2).joined(separator: " ")
    }

    // MARK: - Topic word

    /// Words that name nothing on their own. Standard stopwords plus the filler
    /// this corpus produces ("session", "work", "update") — a callsign built from
    /// one of these distinguishes no session from any other.
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "for", "to", "in", "on",
        "with", "from", "into", "onto", "via", "at", "by", "as", "is", "are",
        "was", "were", "be", "been", "being", "it", "its", "this", "that",
        "these", "those", "up", "out", "over", "under", "per", "not", "now",
        "new", "session", "work", "task", "update", "updates",
    ]

    /// Candidate topic words, most distinctive first. Distinctiveness is a
    /// deterministic proxy: longest word wins, ties broken by position (earlier
    /// words in a 3-6 word topic tend to carry the subject). Skips stopwords,
    /// the directory word itself, bare numbers, and anything under 3 letters.
    static func candidateTopicWords(topic: String, directoryWord: String) -> [String] {
        // The directory prefix may itself be several plain words now; a topic
        // word matching ANY of them adds nothing ("facts cache cache").
        let dirWords = Set(directoryWord.lowercased().split(separator: " ").map(String.init))
        var seen = Set<String>()
        let filtered = topic.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { word in
                word.count >= 3 && !stopwords.contains(word) && !dirWords.contains(word)
                    && !word.allSatisfy(\.isNumber) && seen.insert(word).inserted
            }
        return filtered.enumerated().sorted { a, b in
            a.element.count != b.element.count
                ? a.element.count > b.element.count
                : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Minting

    /// Deterministic, no model call. Returns nil when the topic offers no usable
    /// word (a deterministic-floor topic is just the project label) — the caller
    /// then speaks the directory word alone and mints later, rather than
    /// freezing a wordless callsign forever.
    public static func mint(
        directoryWord: String, topic: String, existingCallsigns: [String]
    ) -> String? {
        let candidates = candidateTopicWords(topic: topic, directoryWord: directoryWord)
        guard !candidates.isEmpty else { return nil }

        for word in candidates {
            let candidate = "\(directoryWord) \(word)"
            if !collides(candidate, topicWord: word, with: existingCallsigns) {
                return candidate
            }
        }

        // Every candidate collides with an active callsign: append a
        // distinguishing word from the topic to the most distinctive one.
        // Three words is the ceiling (ruled 06 Aug — a callsign is spoken, and
        // two words ideally, three at worst is what a voice can carry), so a
        // two-word directory prefix gives up its first word to make room.
        let first = candidates[0]
        let dirTail = directoryWord.split(separator: " ").last.map(String.init)
            ?? directoryWord
        let rawWords = topic.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for extra in (candidates.dropFirst() + rawWords)
        where extra != first && extra != dirTail {
            let candidate = "\(dirTail) \(first) \(extra)"
            if !existingCallsigns.contains(where: {
                $0.caseInsensitiveCompare(candidate) == .orderedSame
            }) {
                return candidate
            }
        }
        // Nothing left to distinguish with. Accept the near-collision rather
        // than fail: a confusable name still beats no name.
        return "\(directoryWord) \(first)"
    }

    /// Exact collision: case-insensitive equality of the full callsign.
    /// Near-collision: Levenshtein distance <= 2 between topic words — "copy"
    /// vs "code" are indistinguishable at speech speed.
    static func collides(
        _ candidate: String, topicWord: String, with existing: [String]
    ) -> Bool {
        for other in existing {
            if other.caseInsensitiveCompare(candidate) == .orderedSame { return true }
            let otherTopic = other.split(separator: " ").last.map(String.init) ?? other
            if levenshtein(topicWord.lowercased(), otherTopic.lowercased()) <= 2 {
                return true
            }
        }
        return false
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let substitution = previous[j - 1] + (aChars[i - 1] == bChars[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }

    // MARK: - Prefix stripping

    /// Remove every leading "<label>:" the model may have written — the project
    /// label, the live session name, or the callsign itself, case-insensitively —
    /// looping so that "promotions: promotions:" collapses entirely. The caller
    /// then prepends the minted callsign exactly once, which is what makes a
    /// doubled prefix impossible by construction rather than by model compliance.
    public static func strippingLabelPrefixes(_ text: String, labels: [String]) -> String {
        var out = text.trimmingCharacters(in: .whitespaces)
        var stripped = true
        while stripped {
            stripped = false
            for label in labels where !label.isEmpty {
                guard out.count > label.count,
                      out.lowercased().hasPrefix(label.lowercased())
                else { continue }
                let afterLabel = out.index(out.startIndex, offsetBy: label.count)
                let rest = out[afterLabel...].drop(while: { $0 == " " })
                guard rest.first == ":" else { continue }
                out = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                stripped = true
                break
            }
        }
        return out
    }
}
