import Foundation

/// Whether a modal is shown again, or only recorded.
///
/// Ruled 19 Sep, after ten "Unable to Check For Updates" dialogs landed in
/// fourteen minutes: a person never sees the same alert twice in a row
/// inside `window`. Every alert is still RECORDED every time, through
/// `Failures.report`, because that record is what reaches Slack; this only
/// decides whether the person is interrupted as well. Pure, with the clock
/// and the history injected, so a test can drive both and the app can keep
/// the history across launches (a repeat from a fresh process is still a
/// repeat to the person watching the screen).
public struct AlertGate: Sendable {
    /// Ten minutes. Long enough that a loop cannot land a second copy while
    /// the first is still on screen, short enough that tomorrow's alert is
    /// tomorrow's.
    public static let window: TimeInterval = 10 * 60

    public enum Verdict: Equatable, Sendable {
        case show
        /// Withheld: the same key was shown this many seconds ago.
        case withheld(secondsAgo: Int)
    }

    /// When each key was last SHOWN (withheld repeats do not move it, so a
    /// steady drip still surfaces once per window rather than never).
    public private(set) var lastShown: [String: Date]

    public init(lastShown: [String: Date] = [:]) {
        self.lastShown = lastShown
    }

    /// Decide for one alert, and remember the decision.
    public mutating func admit(_ key: String, at now: Date = Date(),
                               window: TimeInterval = AlertGate.window) -> Verdict {
        if let previous = lastShown[key] {
            let age = now.timeIntervalSince(previous)
            // A clock that went backwards (sleep, NTP) reads as "long ago",
            // never as "just now": withholding on a bad clock hides an alert.
            if age >= 0, age < window {
                return .withheld(secondsAgo: Int(age))
            }
        }
        lastShown[key] = now
        return .show
    }
}
