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
}
