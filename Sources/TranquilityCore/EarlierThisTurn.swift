import Foundation

/// What the agent said this turn before its final message.
///
/// Tranquility Base summarises a turn: everything the agent said since the
/// person last spoke to it. Every adapter used to hand the summariser one
/// message, the last one, so a turn that worked for twenty minutes and signed
/// off "watching quietly" was summarised as watching quietly (17 Sep). The
/// final message stays its own thing, because the prompt's sharpest rule is
/// that a proposal comes only from there; this is the rest of the turn,
/// oldest first, for the recap and the findings.
///
/// One rule for every adapter: the agent's prose blocks of the turn, in order,
/// final last; drop the final one; join; cap. `TurnText` already yields the
/// blocks for Claude Code and Codex from their transcripts, and a polled
/// provider's transcript is a role/text list the caller slices. Where the
/// blocks come from is the only thing that differs between agents.
public enum EarlierThisTurn {

    /// The cap, and how it is cut: a long turn keeps its opening and its end,
    /// because the opening says what was being attempted and the end says
    /// where it got to. Measured turns top out around three thousand
    /// characters, so this is a ceiling for the pathological turn, and it is
    /// the contract's `maxLength` for the field.
    public static let cap = 6_000
    static let head = 1_500

    /// Everything but the last block, joined oldest first. Nil when the turn
    /// was one message.
    public static func earlier(blocks: [String]) -> String? {
        let prose = blocks
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard prose.count > 1 else { return nil }
        return capped(prose.dropLast().joined(separator: "\n\n"))
    }

    /// First 1,500 and last 4,500 characters with a marker between, when the
    /// text is over the cap. Counted in characters, cut on character bounds,
    /// and the result is always under the cap including the marker.
    public static func capped(_ text: String) -> String {
        guard text.count > cap else { return text }
        let marker = { (n: Int) in "\n[… \(n) characters omitted …]\n" }
        let room = cap - marker(text.count).count
        let tail = room - head
        let omitted = text.count - head - tail
        return String(text.prefix(head)) + marker(omitted) + String(text.suffix(tail))
    }
}
