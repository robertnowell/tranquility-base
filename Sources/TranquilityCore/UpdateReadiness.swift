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
}
