import Foundation

/// What the user was answering.
///
/// The user hears Tranquility Base, not the agent. The summariser compresses a
/// turn to one recap and one proposal; its own prompt says ONE action per
/// proposal, name the agent's preferred one when the source offers
/// alternatives, and when in doubt, ask. So when the agent asks three
/// questions the user hears one, and when the agent asks none the user may
/// still hear "Proceed?". The reply answers THAT, and until 11 Sep 2026 only
/// the answer reached the agent: "go ahead", against three questions it had
/// asked and one it had not. Ambiguous to the agent, never to the user.
///
/// Ruled 11 Sep: every dispatched reply carries the spoken recap and proposal,
/// and NOTHING else from the brief. Not the ladder: its deeper rungs are heard
/// only on a pull, pulls are not persisted, and the findings and solution
/// rungs are a paraphrase of the agent's own turn, which an agent would read
/// as the user asserting it back.
///
/// The note LEADS. What they heard, then what they said in reply, in that
/// order, as one message: "here is what the user heard, here is what they
/// said." Ruled 13 Sep 2026, reversing the first cut's trailing note, which
/// was chosen to keep the user's own words first on the undo card. The
/// ruling: this is a message-layer fact and reads in the order it happened;
/// the card shows the same order. It is also how the context reaches EVERY
/// harness. A Codex session gets no Claude Code session-start briefing, and
/// the bracket has to stand alone there, so it says who spoke and what the
/// words after it are, and nothing more. No hedge about the summariser being
/// wrong (proposed 12 Sep, refused 13 Sep): a guard sentence on every send is a gate
/// on a model error, and the repair for those is the summariser's context.
///
/// The framing is two labels and nothing else, ruled 13 Sep after the first
/// live bracket ("[Tranquility Base read the user this summary of your
/// previous turn, by voice: ... They replied:]") was heard back: "that's too
/// much. We can just put assistant, colon, in brackets." So: `[assistant]:`
/// then what was spoken, `[user]:` then what they said. The user label is
/// there because the blank line between the two paragraphs arrives as a
/// single space through Claude Code's composer (measured 13 Sep, transcript
/// bytes), so without it the boundary between the paraphrase and the reply
/// would be unmarked.
///
/// Pure functions. The brief they quote is read by the Coordinator from the
/// utterance's OWN event, bound at capture, never from the session's current
/// latest event, which can move during the undo window.
public enum HeardContext {
    /// The label on what was spoken. Bare, on purpose.
    public static let assistantLabel = "[assistant]:"
    /// The label on what they said. Present only when there is a note.
    public static let userLabel = "[user]:"

    /// The note, or nil when there is nothing spoken to quote. An event with
    /// no brief (a launch greeting, a summariser floor, a turn the user was
    /// deep-linked to before it was announced) dispatches the transcript
    /// byte-identical to before this existed.
    public static func note(recap: String?, proposal: String?) -> String? {
        let spoken = [recap, proposal]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !spoken.isEmpty else { return nil }
        return assistantLabel + " " + spoken
    }

    /// The note, then the labelled message. `message` is already the tray's
    /// composition (fragments, then transcript): everything the user is
    /// sending. No note, no label: the bare message, byte-identical to
    /// before any of this existed.
    public static func compose(note: String?, message: String) -> String {
        guard let note else { return message }
        return message.isEmpty ? note : note + "\n\n" + userLabel + " " + message
    }
}
