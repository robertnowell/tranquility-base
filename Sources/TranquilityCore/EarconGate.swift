import Foundation

/// Whether *now* is an acceptable moment to make a small sound.
///
/// Deliberately much dumber than `InterruptGate`, and deliberately separate from
/// it. That gate exists to veto SPEECH — it defers an announcement to a
/// breakpoint, reads idle time, asks who is frontmost, and shells out to
/// `lsappinfo` to do it. None of that applies here. Ruled 18 Aug:
///
/// > "We don't need to defer. If the mic is actively listening, then you can
/// > assume I'm going back to the grid after I finish my current turn and I will
/// > see the lamps. So the only reason to audio alert at all is the user is not
/// > currently looking at the grid… Anything complicated here is basically just
/// > alert channel open or alert channel not open. We don't need to enqueue
/// > things and then play a bunch of alerts at the end. That's just surface for
/// > bugs."
///
/// So: the channel is open or it is not, and a cue that arrives on a closed
/// channel is DROPPED. Never queued, never deferred, never replayed. The design
/// that got rejected had a stale-drop timer, a coalescing window and a deferred
/// replay — three pieces of state to get wrong, whose failure mode was a burst of
/// cues at the end of a turn.
///
/// One asymmetry, and it is load-bearing: `listening` is exempt from the
/// user-is-speaking veto, because `listening` IS the announcement that the
/// microphone just opened. The mic being open is its trigger, so vetoing on it
/// would mean the cue could never fire at all.
public struct EarconGate: Sendable, Equatable {

    public enum Cue: String, Sendable, CaseIterable {
        /// The microphone is open and audio is provably flowing. "Go ahead."
        case listening
        /// The undo window closed: the words are on their way. "Done."
        case dispatched
        /// An agent came back with something. "Your move."
        case returned
        /// Blocked, failed, or waiting on a decision only a human can make.
        case needsYou
    }

    /// The microphone is open — the user is talking, or about to.
    public var userIsSpeaking: Bool
    /// Text-to-speech is playing, or paused mid-utterance.
    public var agentIsSpeaking: Bool

    public init(userIsSpeaking: Bool, agentIsSpeaking: Bool) {
        self.userIsSpeaking = userIsSpeaking
        self.agentIsSpeaking = agentIsSpeaking
    }

    public func allows(_ cue: Cue) -> Bool {
        if agentIsSpeaking { return false }
        if userIsSpeaking { return cue == .listening }
        return true
    }

    /// Why a cue was dropped, for the log. Nil when it was allowed.
    public func refusal(for cue: Cue) -> String? {
        if agentIsSpeaking { return "agent is speaking" }
        if userIsSpeaking, cue != .listening { return "mic is open" }
        return nil
    }
}
