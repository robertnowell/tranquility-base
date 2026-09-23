import Foundation

/// What a modifier release means, decided in one place and unit-tested.
///
/// Measured 14 Sep 2026 on a new Mac: three hours of use, zero ⌃⌥ events,
/// and its owner's report was "Control worked, Option worked, both together
/// did nothing". The monitor accepted a two-key chord only if both keys were
/// back up within the 200 ms hold threshold, and dropped a longer press
/// without a line of log. Nobody presses "Control plus Option" in 200 ms the
/// first time they are told to.
///
/// The threshold exists for the single-modifier gestures, where a tap and a
/// hold are different instructions: ⌥ tapped arms, ⌥ held replies, and the
/// hold's meaning is delivered while the key is down, so its release must not
/// also count as a tap. A chord of two modifiers has no hold meaning to
/// protect. Its length is not evidence of anything, and it counts however
/// long it was held, as long as nothing else was pressed inside it.
public enum ChordRelease {
    public enum Verdict: Equatable {
        /// Act on what was pressed.
        case fires
        /// Another key or a click landed during the press: a real shortcut
        /// (⌃C, ⌥-drag), never one of ours.
        case interfered
        /// A single modifier held past the tap window. Whatever the hold
        /// meant was already delivered; the release is not a tap.
        case heldPastTap
    }

    /// `modifiers` is how many of ⌃ ⌥ ⇧ ⌘ the press grew to include.
    /// `hasHoldMeaning` is false for a lone modifier whose hold does nothing
    /// of its own: ⇧, which only pauses. The same argument as the chord's
    /// applies to it, and it was measured the same way: on 22 Sep, 40 lone ⇧
    /// presses were dropped as "not a tap", median 319 ms, while the speech
    /// they were meant to pause kept going.
    public static func verdict(modifiers: Int, duration: TimeInterval,
                               holdThreshold: TimeInterval, interfered: Bool,
                               hasHoldMeaning: Bool = true) -> Verdict {
        if interfered { return .interfered }
        if modifiers >= 2 || !hasHoldMeaning { return .fires }
        return duration < holdThreshold ? .fires : .heldPastTap
    }
}
