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
enum PanelState: Equatable {
    case hidden
    case idle(waiting: Int)
    case preparing
    case speaking(eventId: String?, catchUp: Bool)
    case paused(eventId: String?)
    case listening(eventId: String?)
    case transcribing(startedAt: Date)
    case pendingSend(utteranceId: String)
    case result(ok: Bool)
    case settings

    /// Short, stable name for logs. Deliberately excludes ids so a transition line
    /// reads as a state change rather than a data dump.
    var name: String {
        switch self {
        case .hidden: return "hidden"
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .speaking(_, let catchUp): return catchUp ? "catchingUp" : "speaking"
        case .paused: return "paused"
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .pendingSend: return "pendingSend"
        case .result(let ok): return ok ? "result.ok" : "result.failed"
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
        case .speaking, .paused, .pendingSend, .result: return true
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
            case .transcribing, .listening, .result(ok: false): return true
            default: return false
            }
        case .transcribing:
            switch next {
            // result (both kinds) is the normal send-receipt path: the countdown
            // expiring shows "Sending to…" (transcribing) and the receipt follows.
            case .pendingSend, .listening, .transcribing, .result: return true
            default: return false
            }
        case .pendingSend:
            switch next {
            case .result(ok: false), .transcribing, .listening: return true
            default: return false
            }
        // A late success receipt must not repaint over live or preparing speech —
        // this absorbs the send-path "somethingElseOnStage" guard. Failures always
        // surface: they are the case with work left to do.
        case .preparing, .speaking, .paused:
            if case .result(ok: true) = next { return false }
            return true
        // Everything else admits everything — exactly today's behavior.
        case .hidden, .idle, .result, .settings:
            return true
        }
    }
}
