import Foundation

/// What one bare ⌥ tap means, as a pure function of the state it arrives in.
///
/// This exists because the ⌥ handler broke twice on 10 Aug and neither break was
/// catchable: it lived in `main.swift`, which has no unit tests, so the evidence
/// for "a tap while speaking opens the microphone" was somebody reading the code
/// and saying so. That is not evidence, and the user paid for it — six presses
/// ignored while the app talked over them, then a fix that took a waiting agent
/// out of the queue and gave nothing back.
///
/// The decision is separated from the doing so the decision can be asserted.
/// `main.swift` still owns the side effects; it no longer owns the reasoning.
///
/// **The rule, ruled 10 Aug and absolute:** while the app is speaking, ⌥ lets
/// you speak. Not "usually", not "if the second tap lands inside 450ms". The
/// first test below is that sentence, and it is the one that must never go red.
public enum OptionTapDecision: Sendable, Equatable {
    /// A capture is live and no key is held: this tap ends it and sends. The
    /// mirror of releasing a held key, and the escape hatch from a capture whose
    /// release was lost.
    case endCapture
    /// Open the microphone and latch hands-free, so the next tap sends.
    case startListening
    /// Nothing yet — remember it, in case a second tap follows quickly.
    case armFirstOfPair
    /// The microphone is not ours to open — or this tap is the twin of one that
    /// just opened it, and closing what it opened is never what was meant.
    case ignore

    /// - Parameters:
    ///   - isSpeaking: the panel is reading something out loud right now.
    ///   - isRecording: the recorder is capturing.
    ///   - isArmed: an arm window is open (a key is physically held), which makes
    ///     this tap part of a hold rather than a gesture in its own right.
    ///   - withinPairWindow: a previous bare tap landed recently enough to pair.
    ///   - listeningJustStarted: the capture began inside the same pair window,
    ///     which means this tap is the second half of a ⌥⌥ rather than an intent
    ///     to send.
    ///   - micGranted: microphone permission.
    public static func decide(
        isSpeaking: Bool,
        isRecording: Bool,
        isArmed: Bool,
        withinPairWindow: Bool,
        listeningJustStarted: Bool = false,
        micGranted: Bool
    ) -> OptionTapDecision {
        // THE TWIN. Once a tap while speaking opens the microphone immediately,
        // the SECOND tap of the user's ⌥⌥ arrives into a live capture and reads
        // as "send" — so the pair opens the microphone and closes it again
        // roughly 300ms later, with nothing said. Observed 10 Aug 00:55:11–12:
        // startListening, then endCapture in the same second, then the silence
        // gate reporting nothing heard and the panel falling back to the grid.
        //
        // Nobody opens a microphone and sends a third of a second later having
        // said nothing. A tap that lands inside the pair window of the capture
        // it would be ending is the tail of the gesture that started it, and is
        // swallowed.
        if isRecording, !isArmed, listeningJustStarted { return .ignore }

        // Ending a live capture comes first and is unconditional — it must work
        // even without permission state being consulted, because the capture it
        // is ending already exists. A capture with no way out is the trust-killer.
        if isRecording, !isArmed { return .endCapture }
        guard micGranted else { return .ignore }

        // THE RULE. While we are talking, one tap is the whole gesture. No
        // pairing, no window, no timing to get right: the moment the user
        // reaches for the key while being talked at, they want the floor.
        if isSpeaking { return .startListening }

        // From anywhere else, two quick taps ask for hands-free — the pairing
        // exists because a single tap has other meanings when we are NOT talking.
        return withinPairWindow ? .startListening : .armFirstOfPair
    }
}
