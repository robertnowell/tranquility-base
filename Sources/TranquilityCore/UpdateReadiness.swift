import Foundation

/// Whether it is safe to replace the running app right now.
///
/// Sparkle's default is to terminate the app and relaunch it. This app holds live
/// coding sessions and a microphone, so "quit now" is not a neutral act: an update
/// landing mid-hold eats the audio, and one landing mid-dispatch eats the reply.
/// The ruling is that an update NEVER interrupts. It downloads whenever, and waits
/// for a moment when nothing is in motion.
///
/// One predicate, not two. `PanelState` already exists because five booleans
/// disagreed about what "busy" meant (see PanelState's own header for the bug that
/// cost). Adding a sixth boolean inside the updater would recreate exactly that,
/// one layer up, and it would be the version nobody looks at because it only runs
/// on the machines of people who are not us.
///
/// The switch is deliberately exhaustive with no `default:`. A new panel state must
/// state whether an update may land on top of it, at the point where the state is
/// added, rather than silently inheriting "yes".
public enum UpdateReadiness {

    /// Why an install is being held back, or `nil` when it may proceed.
    ///
    /// Named rather than boolean because this shows up in the log and in the
    /// `--selftest` drill, and "postponed" with no reason is the kind of line that
    /// wastes an afternoon later.
    public enum Block: String, Equatable, Sendable {
        /// The microphone is open, or the panel is mid-interaction.
        case panelEngaged = "panel engaged"
        /// Audio has been captured and has not yet reached its session.
        case utterancesInFlight = "utterances in flight"
    }

    /// The whole rule.
    ///
    /// - Parameters:
    ///   - panel: what the panel is doing, straight from `StatusHUD.state`.
    ///   - inFlightUtterances: how many rows sit in `UtteranceStatus.inFlight`,
    ///     which is the queue's own canonical answer to "is anything unfinished".
    ///     Reusing that set is the point: the boot sweep, the retention sweep and
    ///     the updater now agree by construction about what unfinished means.
    public static func block(
        panel: PanelState,
        inFlightUtterances: Int
    ) -> Block? {
        switch panel {
        // Nothing on screen, or an idle grid. The only two moments an update may
        // land. `.idle` carries a waiting count, but waiting sessions are the
        // agents' state, not ours: they survive a relaunch untouched.
        case .hidden, .idle:
            break

        // The microphone is live or about to be, words are being turned into text,
        // or a send is one keystroke from happening. Interrupting any of these
        // loses something the user said out loud, which is the one thing this app
        // promises never to do (docs/rulings/ruling-no-second-of-audio-is-ever-lost.md).
        case .arming, .listening, .transcribing, .pendingSend:
            return .panelEngaged

        // The app is talking. Cutting it off mid-sentence is not data loss, but it
        // is the rudest possible moment, and "preparing" is the half-second before
        // it starts.
        case .preparing, .speaking:
            return .panelEngaged

        // A face the person is reading: a failure, a dictation receipt, the
        // settings pane, the graveyard. Nothing durable is lost by relaunching
        // under them, but the panel would vanish mid-read with no explanation.
        case .result, .receipt, .settings, .pastAgents:
            return .panelEngaged
        }

        // The panel is quiet, but the queue may not be: a reply can be dispatching
        // to a session with no panel on screen at all.
        return inFlightUtterances > 0 ? .utterancesInFlight : nil
    }

    /// How often to re-ask once an install has been postponed.
    ///
    /// Sparkle hands over a block to invoke when ready and then waits, so this is
    /// a poll rather than a notification. Ten seconds is short enough that a
    /// finished session installs promptly and long enough that a machine left
    /// recording for an hour is not doing this thousands of times.
    public static let recheckInterval: TimeInterval = 10

    /// How often a running app asks the feed. Every merge is a release, and
    /// the app is never quit (Robert, 09 Sep: "I don't really close
    /// Tranquility Base, nor should I"), so the daily check that shipped on
    /// 7 Sep, which the 09 Sep log actually showed as weekly, left a running
    /// app five releases behind. One hour is Sparkle's floor.
    public static let checkInterval: TimeInterval = 3600

    /// Whether an update-check error means the feed was never reached: no
    /// network, DNS, a timeout, a lost connection. These fire on every asleep
    /// or offline install each time the scheduled timer ticks, so the updater
    /// records them as data and NEVER alerts on them; routing the offline case
    /// to the failure stream would storm the alert channel fleet-wide, on
    /// Apple Silicon too (ruled 12 Sep). A check that reached the feed and
    /// still failed (a bad signature, a malformed appcast, an HTTP status) is a
    /// real failure and is not offline. Sparkle sometimes wraps the transport
    /// error under its own, so the underlying error is inspected as well.
    public static func isOffline(_ error: NSError) -> Bool {
        func transportOffline(_ e: NSError) -> Bool {
            guard e.domain == NSURLErrorDomain else { return false }
            switch e.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed, NSURLErrorTimedOut:
                return true
            default:
                return false
            }
        }
        if transportOffline(error) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           transportOffline(underlying) { return true }
        return false
    }

    /// How many consecutive idle polls an install waits for. One idle poll is
    /// an instant; the grid is idle for a moment between a read-back ending
    /// and the next press. Two polls, twenty seconds apart, is a person who
    /// has actually stepped away from the panel, and the relaunch that
    /// follows lands on nobody. Ruled 09 Sep: "truly at a safe juncture".
    public static let requiredIdlePolls = 2

    /// The install gate, as a value the delegate carries between polls.
    ///
    /// `observe` is fed the block (or nil) on every poll and answers whether
    /// the install may go now. A busy poll resets the streak, so idle time
    /// must be continuous: an app that flickers busy every few seconds never
    /// installs, which is the right answer for an app somebody is using.
    public struct InstallGate: Equatable, Sendable {
        public private(set) var consecutiveIdlePolls = 0
        public init() {}

        public mutating func observe(_ block: Block?) -> Bool {
            if block == nil {
                consecutiveIdlePolls += 1
            } else {
                consecutiveIdlePolls = 0
            }
            return consecutiveIdlePolls >= UpdateReadiness.requiredIdlePolls
        }
    }
}
