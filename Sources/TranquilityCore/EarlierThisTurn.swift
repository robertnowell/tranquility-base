import Foundation

/// What the agent said this turn before its final message.
///
/// Tranquility Base summarises a turn: everything the agent said since the
/// person last spoke to it. Every adapter used to hand the summariser one
/// message, the last one, so a turn that worked for twenty minutes and signed
/// off "watching quietly" was summarised as watching quietly (17 Sep). The
/// final message stays its own thing, so the most recent correction can override earlier statements. This is
/// the rest of the turn, oldest first, without silently discarding evidence.
///
/// One rule for every adapter: the agent's prose blocks of the turn, in order,
/// final last; drop the final one; join without truncation. `TurnText` already yields the
/// blocks for Claude Code and Codex from their transcripts, and a polled
/// provider's transcript is a role/text list the caller slices. Where the
/// blocks come from is the only thing that differs between agents.
public enum EarlierThisTurn {

    /// Everything but the last block, joined oldest first. Nil when the turn
    /// was one message.
    public static func earlier(blocks: [String]) -> String? {
        let prose = blocks
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard prose.count > 1 else { return nil }
        return prose.dropLast().joined(separator: "\n\n")
    }

}
