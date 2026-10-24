import Foundation

/// What the usage SDK must do to match the toggle (24 Oct 2026).
///
/// The bug this exists for: the SDK persists an opt-out across launches, and
/// the app only ever called optOut, never optIn, at setup. A Mac that once
/// turned usage off and then on again stayed silent after its next relaunch,
/// with the toggle showing on. Turning the toggle on while the SDK had never
/// started (no key yet, or off at launch) did nothing until a relaunch either.
public enum TelemetryConsent {
    public enum Action: Equatable { case start, optIn, optOut }

    public static func actions(enabled: Bool, started: Bool, optedOut: Bool) -> [Action] {
        if enabled {
            if !started { return [.start, .optIn] }
            return optedOut ? [.optIn] : []
        }
        return started && !optedOut ? [.optOut] : []
    }
}
