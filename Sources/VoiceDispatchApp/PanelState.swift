import Foundation

/// What the panel is doing, as one value rather than five booleans.
///
/// It was five: isRecording, isListening, isSpeakingNow, awaitingConfirm, isIdle.
/// Every guard picked its own subset, and the subsets disagreed. `isBusyOnScreen`
/// tested isRecording — the flag the Reply button sets — and never isListening, the
/// flag the hold gesture sets, so Escape did nothing during the single most common
/// interaction in the app. Nobody noticed, twice, because nothing about the code
/// said those two flags were describing the same idea.
///
/// One case per state makes that class of bug unrepresentable: a question like "can
/// Escape act here" is answered once, in one place, for every state at once.
/// Enum hygiene (simplification pass, ruled): `.paused` is deleted — ⇧ pause is
/// an AUDIO behavior; the visual is the frozen speaking card, so there was no
/// panel state to represent (no transition ever entered it). `.speaking`'s
/// catchUp flag is deleted — nothing in production ever set it (only the pose
/// driver did). `.result`'s ok flag is deleted — the Sent face is dead, so a
/// result on screen is always a failure.
enum PanelState: Equatable {
    case hidden
    case idle(waiting: Int)
    case preparing
    case speaking(eventId: String?)
    case listening(eventId: String?)
    case transcribing(startedAt: Date)
    case pendingSend(utteranceId: String)
    case result
    case settings

    /// Short, stable name for logs. Deliberately excludes ids so a transition line
    /// reads as a state change rather than a data dump.
    var name: String {
        switch self {
        case .hidden: return "hidden"
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .speaking: return "speaking"
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .pendingSend: return "pendingSend"
        case .result: return "result.failed"
        case .settings: return "settings"
        }
    }

    /// Escape means "stop what is happening here". It is live wherever something is
    /// happening, which now includes listening and settings — the two states where
    /// it silently did nothing.
    var acceptsEscape: Bool {
        switch self {
        case .hidden: return false
        case .idle, .result: return true          // hide the panel
        default: return true                       // stop the thing in progress
        }
    }

    /// The microphone is open. Announcing into this would record itself.
    var isCapturingAudio: Bool {
        if case .listening = self { return true }
        return false
    }

    /// A reply can be started. Recording with nothing to answer spends a
    /// transcription to discover it had nowhere to go.
    var canStartReply: Bool {
        switch self {
        case .speaking, .pendingSend, .result: return true
        case .hidden, .idle, .preparing, .listening, .transcribing, .settings: return false
        }
    }

    /// A turn arriving may raise the panel. Anything mid-conversation says no.
    var allowsAmbientSurface: Bool {
        switch self {
        case .hidden, .idle: return true
        default: return false
        }
    }

    var isPendingSend: Bool {
        if case .pendingSend = self { return true }
        return false
    }

    /// The reply flow owns the stage from mic-open to resolution. These are the
    /// states a stale repaint must never replace.
    var ownsStage: Bool {
        switch self {
        case .listening, .transcribing, .pendingSend: return true
        default: return false
        }
    }

    /// Which arrivals may replace this state.
    ///
    /// Capture states (listening, transcribing, pendingSend) own the stage: only
    /// their own flow, a failure, or an explicit user teardown (`StatusHUD.endCapture`)
    /// may follow them. The incident this encodes: a gesture opened the mic, the
    /// gesture's own `speech.stop()` woke the interrupted announce task, and its
    /// idle repaint painted "Ready" over a live microphone — after which every
    /// reply gesture silently refused because the recorder never stopped
    /// (app.log 2026-08-05T18:30:30Z). That repaint is now refused here, by type,
    /// instead of being guarded against at each of its call sites.
    func admits(_ next: PanelState) -> Bool {
        switch self {
        case .listening:
            switch next {
            case .transcribing, .listening, .result: return true
            default: return false
            }
        case .transcribing:
            switch next {
            // result is the failure-receipt path: successes never paint a card
            // (the Sent face is dead), so nothing success-shaped arrives here.
            case .pendingSend, .listening, .transcribing, .result: return true
            default: return false
            }
        case .pendingSend:
            switch next {
            case .result, .transcribing, .listening: return true
            default: return false
            }
        // Everything else admits everything. The old "refuse a late success
        // receipt over live speech" guard died with the Sent face: there is no
        // success receipt left to refuse.
        case .hidden, .idle, .preparing, .speaking, .result, .settings:
            return true
        }
    }
}
