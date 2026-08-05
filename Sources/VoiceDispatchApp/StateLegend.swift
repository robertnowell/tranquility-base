import AppKit
import VoiceDispatchCore

/// The single source of truth for how every panel state presents itself.
///
/// Before this file, the state glyphs lived as a dozen scattered string literals
/// inside StatusHUD, and the hint-text chain was pasted verbatim in two places that
/// could only drift apart. This is a centralization pass, not a redesign: every
/// glyph, label, hint and color below is EXACTLY what the panel rendered before the
/// file existed. A later work stream may retune them; this one must not.
///
/// Grep contract: the state glyph characters (◌ ◀ ↺ ❙❙ ▶ ⚠ → ● ‹ › ✕ ✓ ✗) are
/// defined here and nowhere else in this module.
@MainActor
enum StateLegend {

    // MARK: - Glyphs

    /// Every state glyph in the app, defined once.
    enum Glyph {
        /// Quiet/ambient states: ready, preparing, working, the waiting count, and
        /// the menu-bar placeholder before the SF Symbol loads.
        static let quiet = "◌"
        static let speaking = "◀"
        static let catchingUp = "↺"
        static let paused = "❙❙"
        static let sent = "▶"
        static let needsYou = "⚠"
        /// Direction of travel: pending sends and dictation destinations.
        static let routing = "→"
        /// The live dot: the listening pill, the busy menu-bar text fallback, and
        /// the onboarding permission dot.
        static let dot = "●"
        static let back = "‹"
        static let forward = "›"
        static let discard = "✕"
        /// Also the "granted" mark in the menu's permission rows.
        static let confirm = "✓"
        static let denied = "✗"
    }

    // MARK: - Lenses

    /// A semantic role, not a color. Today each lens maps to the NSColor the panel
    /// already uses; a future theme changes the mapping here and nowhere else.
    enum Lens {
        /// Chrome: the state pill and secondary controls.
        case chrome
        /// Primary content: titles and body text.
        case content
        /// De-emphasized guidance: the hint line.
        case guidance
        /// Calls to action: accent-tinted controls.
        case action

        var color: NSColor {
            switch self {
            case .chrome: return .secondaryLabelColor
            case .content: return .labelColor
            case .guidance: return .tertiaryLabelColor
            case .action: return .controlAccentColor
            }
        }
    }

    /// Whether being in the state involves the app making sound. Descriptive today
    /// (nothing consults it yet); WS-A's announcement tiers will.
    enum SpeakTier {
        /// The app is speaking, or about to.
        case speaks
        /// Visual only.
        case silent
    }

    // MARK: - Rows

    /// One row of the legend: how a display situation presents itself.
    struct Row {
        /// Full state-pill text, glyph included, verbatim.
        let stateText: String
        let glyph: String
        let lens: Lens
        let speakTier: SpeakTier
        /// Whether the Reply / Go to session / Dismiss row belongs on screen.
        /// Load-bearing: StatusHUD.render() derives the action row's visibility
        /// from this, for every state that has a Row.
        let showsControls: Bool
    }

    // MARK: - Session grid (WS-B)

    /// The state lamp on a grid row. Flat state color, no skeuomorphism (ruled);
    /// the MOCR palette arrives through this seam in a later item.
    ///
    /// Mapping is limited to what is derivable today: a session in the waiting set
    /// is `.ready`; any other live session is `.running`. `.fault` is defined so
    /// the seam is complete, but nothing observable emits it yet — inventing a
    /// fault state the app cannot actually see is worse than omitting the color.
    enum Lamp: Equatable {
        /// Green: waiting on you.
        case ready
        /// Quiet: alive, nothing waiting.
        case running
        /// Amber: fault. Defined for the seam; unproduced today.
        case fault

        var color: NSColor {
            switch self {
            case .ready: return .systemGreen
            case .running: return Lens.chrome.color
            case .fault: return .systemOrange
            }
        }
    }

    /// One row of the idle grid: a session, its lamp, and a short topic.
    /// Equatable so the intake timer can refresh the grid only when content
    /// actually changed, not on every poll.
    struct SessionRow: Equatable {
        let id: String
        /// The one identity: the minted callsign, else the fallback label.
        let name: String
        /// Short derived topic; may be empty.
        let topic: String
        let lamp: Lamp
    }

    /// The one identity, resolved once: the minted callsign wins everywhere;
    /// the fallback (project label or live session name) covers unminted sessions.
    static func displayName(callsign: String?, fallback: String) -> String {
        if let callsign, !callsign.isEmpty { return callsign }
        return fallback
    }

    /// The short topic for a session: first sentence of the summary, else the
    /// first 60 characters of the last assistant message. ONE derivation — the
    /// grid and every other consumer share it, so they cannot drift apart.
    static func topic(summary: String?, lastAssistantMessage: String?) -> String {
        if let first = summary?.split(separator: ".").first.map(String.init),
           !first.isEmpty {
            return first
        }
        return lastAssistantMessage.map { String($0.prefix(60)) } ?? ""
    }

    /// Display situations. Mostly 1:1 with PanelState; the extras (catch-up, the
    /// two result flavors, the elapsed-seconds working pill) are display
    /// distinctions the enum folds into associated values.
    enum Situation {
        case ready
        case preparing
        case working
        /// Sanctioned change (open issue #4): transcription with visible elapsed time.
        case workingFor(seconds: Int)
        case speaking
        case catchingUp
        case paused
        case listening(target: String)
        case sendingTo(label: String)
        case sent
        case needsYou
        case settings
    }

    static func row(for situation: Situation) -> Row {
        switch situation {
        case .ready:
            return Row(stateText: "\(Glyph.quiet) Ready", glyph: Glyph.quiet,
                       lens: .chrome, speakTier: .silent, showsControls: true)
        case .preparing:
            return Row(stateText: "\(Glyph.quiet) Preparing", glyph: Glyph.quiet,
                       lens: .chrome, speakTier: .silent, showsControls: true)
        case .working:
            return Row(stateText: "\(Glyph.quiet) Working", glyph: Glyph.quiet,
                       lens: .chrome, speakTier: .silent, showsControls: true)
        case .workingFor(let seconds):
            return Row(stateText: "\(Glyph.quiet) Working · \(seconds)s",
                       glyph: Glyph.quiet, lens: .chrome, speakTier: .silent,
                       showsControls: true)
        case .speaking:
            return Row(stateText: "\(Glyph.speaking) Speaking", glyph: Glyph.speaking,
                       lens: .chrome, speakTier: .speaks, showsControls: true)
        case .catchingUp:
            return Row(stateText: "\(Glyph.catchingUp) Catching up", glyph: Glyph.catchingUp,
                       lens: .chrome, speakTier: .speaks, showsControls: true)
        case .paused:
            return Row(stateText: "\(Glyph.paused) Paused", glyph: Glyph.paused,
                       lens: .chrome, speakTier: .silent, showsControls: true)
        case .listening(let target):
            return Row(stateText: "\(Glyph.dot) \(target)", glyph: Glyph.dot,
                       lens: .chrome, speakTier: .silent, showsControls: false)
        case .sendingTo(let label):
            return Row(stateText: "\(Glyph.routing) Sending to \(label)", glyph: Glyph.routing,
                       lens: .chrome, speakTier: .silent, showsControls: true)
        case .sent:
            return Row(stateText: "\(Glyph.sent) Sent", glyph: Glyph.sent,
                       lens: .chrome, speakTier: .silent, showsControls: true)
        case .needsYou:
            return Row(stateText: "\(Glyph.needsYou) Needs you", glyph: Glyph.needsYou,
                       lens: .chrome, speakTier: .silent, showsControls: true)
        case .settings:
            return Row(stateText: "Settings", glyph: "",
                       lens: .chrome, speakTier: .silent, showsControls: false)
        }
    }

    // MARK: - Hint text

    /// The action line under the panel. One definition; it was previously pasted
    /// verbatim in two places (show() and replyTapped()) that could drift apart.
    /// Order matters and is preserved exactly: listening beats the countdown beats
    /// having no target beats the button-recording flag.
    static func actionHint(isListening: Bool, awaitingConfirm: Bool,
                           hasTarget: Bool, isRecording: Bool) -> String {
        if isListening {
            return "Let go of ⌥ to send, or Dismiss to throw it away."
        }
        if awaitingConfirm {
            return "Sending in a moment. Stop it if that isn't what you said."
        }
        guard hasTarget else { return "" }
        return isRecording
            ? "Listening. Click Send, or let go of ⌥."
            : "Click Reply, or hold ⌥ to speak."
    }

    /// Shown while playback is paused.
    static let pausedHint = "Tap ⇧ to carry on, or Dismiss to be done with it."
    /// Shown while playback is running.
    static let speakingHint = "Tap ⇧ to pause, hold ⌥ to reply."

    // MARK: - Controls

    static let backTitle = "\(Glyph.back) Back"

    // MARK: - Destinations

    /// Dictation destination pills: "→ Terminal", "→ clipboard".
    static func destination(_ name: String) -> String { "\(Glyph.routing) \(name)" }
    static var clipboardDestination: String { destination("clipboard") }

    // MARK: - Slow transcription (sanctioned change: open issue #4)

    static let slowTranscriptionNote = "Taking longer than usual — your audio is safe."
    static let cancelTranscriptionTitle = "Cancel"
    static let retryTranscriptionTitle = "Retry"
    /// After this many seconds of transcribing, say so and offer a way out.
    static let slowTranscriptionThreshold: TimeInterval = 20

    // MARK: - Menu bar

    /// The status item has exactly three states.
    enum MenuBarState { case normal, busy, permissionWarning }

    struct MenuBarAppearance {
        let symbol: String
        /// Used only when the SF Symbol fails to load.
        let textFallback: String
    }

    static func menuBar(_ state: MenuBarState) -> MenuBarAppearance {
        switch state {
        case .normal:
            return MenuBarAppearance(symbol: "waveform.circle", textFallback: "VD")
        case .busy:
            return MenuBarAppearance(symbol: "waveform.circle.fill",
                                     textFallback: "VD\(Glyph.dot)")
        case .permissionWarning:
            return MenuBarAppearance(symbol: "exclamationmark.bubble", textFallback: "VD")
        }
    }

    /// Shown in the instant before the first SF Symbol is set.
    static let menuBarPlaceholder = Glyph.quiet

    /// The annunciator at rest (ruled): the menu-bar item carries the waiting
    /// count as its title next to the symbol; quiet (image only) when nothing is.
    /// The count is always the liveness-filtered one — dead sessions are not
    /// counted anywhere.
    static func menuBarCount(_ waiting: Int) -> String {
        waiting > 0 ? " \(waiting)" : ""
    }

    // MARK: - Readiness, in plain words (sanctioned change b)

    /// User-facing wording for why a session cannot take a reply right now.
    ///
    /// The mapping, case by case:
    /// - `.notRegistered` — alive but absent from `claude agents --json`, which
    ///   verifiably means it is blocked on a dialog (trust/permission prompt) or
    ///   still starting. Injecting would answer the dialog.
    /// - `.targetGone` — the process is gone; there is no tab to type into.
    /// - `.busy` / `.waiting` — these normally dispatch (`canDispatch` is true) and
    ///   should not reach a refusal, but they are named honestly if they ever do.
    /// - `.ready` — unreachable via `sessionNotReady`; named for completeness.
    static func plainWords(for readiness: Readiness) -> String {
        switch readiness {
        case .ready: return "it looks ready"
        case .notRegistered: return "it's blocked on a dialog or still starting up"
        case .busy: return "it's still working on its current turn"
        case .waiting(let what):
            if let what, !what.isEmpty { return "it's waiting on \(what)" }
            return "it's waiting on something in its tab"
        case .targetGone: return "its tab is gone"
        }
    }
}
