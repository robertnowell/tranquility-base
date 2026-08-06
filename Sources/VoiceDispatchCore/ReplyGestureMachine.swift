import Foundation

/// The reply gesture's arm/hold timeline, as a pure state machine.
///
/// Extracted from `HotkeyMonitor` for the instant-arm feature
/// (docs/instant-arm.md) so the timing-sensitive decisions — when the arm
/// window opens, when it aborts, when a hold becomes a reply — are
/// unit-testable with synthetic timelines (safety eval E1). The monitor owns
/// the timers and the CGEvent plumbing; every decision about what those
/// timers and events MEAN is answered here and nowhere else. Time itself
/// never appears: the timers are the clock, and their firings arrive as
/// events, which is what makes a 40ms-vs-200ms timeline expressible in a test
/// as a plain sequence of values.
///
/// The invariant the grace period exists for, stated once: bare ⌥ is also how
/// every ⌥-chord special character starts while typing, so `openArmWindow`
/// may fire ONLY when the reply modifier has been down alone, undisturbed,
/// for the whole grace — a keyDown, a click, or a second modifier before the
/// grace elapses means nothing ever shows.
public struct ReplyGestureMachine: Sendable {
    /// Where the gesture currently stands. `pending` is a press that has not
    /// yet earned anything; `armed` is the open arm window; `replying` is a
    /// resolved hold.
    public enum Phase: Equatable, Sendable {
        case idle, pending, armed, replying
    }

    public enum Event: Equatable, Sendable {
        /// A modifier press began. `isReply` — the held flags are exactly the
        /// reply chord (bare ⌥).
        case began(isReply: Bool)
        /// Another key or a click landed while the modifiers were down: this
        /// is a real shortcut, not one of ours.
        case sawOtherInput
        /// The held flags changed (a second modifier joined). Mirrors the
        /// monitor's `formUnion`: once flags grow past the reply chord,
        /// `isReply` can never come back true within one gesture.
        case flagsChanged(isReply: Bool)
        /// The arm-grace timer fired (~80ms after key-down).
        case graceElapsed
        /// The hold-threshold timer fired (~350ms after key-down).
        case holdElapsed
        /// All modifiers released.
        case released
    }

    /// What the monitor must do in response. Effects arrive in order; a
    /// release that concludes a reply produces exactly one of
    /// `endReply`/`abortReply`, and an armed gesture that dies produces
    /// exactly one `abortArm`.
    public enum Effect: Equatable, Sendable {
        /// Bare ⌥ survived the grace untouched: show the arming face, open
        /// the microphone optimistically.
        case openArmWindow
        /// The arm window closed without becoming a reply: revert the face,
        /// stop and discard the capture.
        case abortArm
        case beginReply
        case endReply
        case abortReply
    }

    public private(set) var phase: Phase = .idle
    /// Whether the gesture's flags are still exactly the reply chord.
    private var isReply = false
    /// Other input was seen: the gesture can never arm or begin a reply, and
    /// a reply already begun ends as an abort.
    private var disqualified = false

    public init() {}

    public mutating func apply(_ event: Event) -> [Effect] {
        switch event {
        case .began(let reply):
            phase = .pending
            isReply = reply
            disqualified = false
            return []

        case .sawOtherInput:
            guard phase != .idle else { return [] }
            disqualified = true
            if phase == .armed {
                // Revert IMMEDIATELY, not at key release: the user is typing
                // ⌥-chord characters and may keep ⌥ down for several of them.
                phase = .pending
                return [.abortArm]
            }
            return []

        case .flagsChanged(let reply):
            guard phase != .idle else { return [] }
            isReply = reply
            if phase == .armed, !reply {
                // The hold grew into a real chord (⌃⌥, ⌥⇧): same immediate
                // revert as other input.
                phase = .pending
                return [.abortArm]
            }
            return []

        case .graceElapsed:
            guard phase == .pending, isReply, !disqualified else { return [] }
            phase = .armed
            return [.openArmWindow]

        case .holdElapsed:
            // Same guard the monitor's holdCheck always had: still pressed,
            // undisturbed, still the reply chord. `armed` implies all three.
            guard phase == .pending || phase == .armed, isReply, !disqualified
            else { return [] }
            phase = .replying
            return [.beginReply]

        case .released:
            defer { phase = .idle; isReply = false; disqualified = false }
            switch phase {
            case .replying:
                return [disqualified ? .abortReply : .endReply]
            case .armed:
                // A clean tap: the arm dies first, then the monitor's own tap
                // classification (⌥ tapped, ⌃⌃, …) runs as it always has.
                return [.abortArm]
            case .pending, .idle:
                return []
            }
        }
    }
}
