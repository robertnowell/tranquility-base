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
/// The note TRAILS the transcript rather than leading it. The undo window
/// shows the exact text that dispatches (the disclosure IS the message, see
/// `Coordinator.confirmAndSend`), and the words the user checks against their
/// own memory have to stay first; a bracket of Tranquility Base's prose ahead
/// of them would push the one thing they are checking off the card.
///
/// Pure functions. The brief they quote is read by the Coordinator from the
/// utterance's OWN event, bound at capture, never from the session's current
/// latest event, which can move during the undo window.
public enum HeardContext {
    /// The bracket's opening. Names the speaker so an agent does not mistake
    /// the quote for its own words or for the user's, and says what the
    /// message above it is.
    public static let opener =
        "[Tranquility Base spoke this summary of your previous turn to the user, "
        + "by voice. The message above is their answer to it:"

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
        return opener + " \u{201C}" + spoken + "\u{201D}]"
    }

    /// The message, then the note. `message` is already the tray's
    /// composition (fragments, then transcript); this adds the one trailing
    /// paragraph and nothing else.
    public static func compose(message: String, note: String?) -> String {
        guard let note else { return message }
        return message.isEmpty ? note : message + "\n\n" + note
    }
}
