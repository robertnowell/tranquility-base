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
public enum PanelState: Equatable {
    case hidden
    case idle(waiting: Int)
    case preparing
    case speaking(eventId: String?)
    /// The instant-arm window (docs/instant-arm.md): bare ⌥ survived the
    /// ~80ms grace and the microphone is capturing optimistically, but the
    /// hold has not yet resolved. The face is the listening pill's geometry
    /// in the faint treatment. A REAL state with its own legality rows, not
    /// a hack around the funnel: it upgrades to `.listening` at
    /// hold-resolution, or reverts to the exact stashed prior face
    /// (StatusHUD.revertArming) when the press turns out to be a tap or a
    /// typing chord.
    case arming
    case listening(eventId: String?)
    case transcribing(startedAt: Date)
    case pendingSend(utteranceId: String)
    case result
    /// The dictation receipt (ui-pass-7, ruling 5): dictation success shows its
    /// card again — "Copied to clipboard: …" / "Typed into X." — because it
    /// tells you where the words went. Distinct from `.result` so the log never
    /// calls a success `result.failed`, and distinct from the dead Sent face:
    /// reply-send success stays silent as ruled; ONLY dictation gets a receipt.
    case receipt
    case settings
    /// The list of everything this machine has run lately — the graveyard, and
    /// the one surface that scrolls. A face rather than a mode: it is opened
    /// deliberately, read, and left, and it does NOT refresh under you while
    /// you are reading it (which is what makes scrolling it safe).
    case pastAgents

    /// Short, stable name for logs. Deliberately excludes ids so a transition line
    /// reads as a state change rather than a data dump.
    public var name: String {
        switch self {
        case .hidden: return "hidden"
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .speaking: return "speaking"
        case .arming: return "arming"
        case .listening: return "listening"
        case .transcribing: return "transcribing"
        case .pendingSend: return "pendingSend"
        case .result: return "result.failed"
        case .receipt: return "receipt"
        case .settings: return "settings"
        case .pastAgents: return "pastAgents"
        }
    }

    /// The panel is reading something out loud right now.
    ///
    /// Exists so the ⌥ handler can ask the question directly rather than pattern
    /// matching on a case it does not otherwise care about: while we are talking,
    /// one tap means stop and listen (ruled 10 Aug).
    public var isSpeaking: Bool {
        if case .speaking = self { return true }
        return false
    }


    /// Escape means "stop what is happening here". It is live wherever something is
    /// happening, which now includes listening and settings — the two states where
    /// it silently did nothing.
    public var acceptsEscape: Bool {
        switch self {
        case .hidden: return false
        case .idle, .result: return true          // hide the panel
        default: return true                       // stop the thing in progress
        }
    }

    /// The microphone is open. Announcing into this would record itself.
    /// `.arming` counts: the optimistic capture is genuinely live.
    /// A card is on stage: an announcement, a ⌃⌃ rung, a failure, a receipt.
    /// ⌃⌥ from any of them means HOME first, never straight to the next agent
    /// (ruled 06 Aug — the error card was still advancing: "it should always
    /// go back to home before it goes to the next agent update").
    ///
    /// `.preparing` counts (18 Aug). It is the announcement's own card — the
    /// same card, a second earlier — and leaving it out was the one place the
    /// home-first law had a hole: ⌃⌥ during a slow summary walked to the NEXT
    /// agent, from a face that had no other way back to the grid. The card you
    /// are waiting for is still a card on stage.
    public var isCardOnStage: Bool {
        switch self {
        case .preparing, .speaking, .result, .receipt: return true
        default: return false
        }
    }

    public var isCapturingAudio: Bool {
        switch self {
        case .listening, .arming: return true
        default: return false
        }
    }

    /// A reply can be started. Recording with nothing to answer spends a
    /// transcription to discover it had nowhere to go.
    public var canStartReply: Bool {
        switch self {
        case .speaking, .pendingSend, .result, .receipt: return true
        case .hidden, .idle, .preparing, .arming, .listening, .transcribing,
             .settings, .pastAgents: return false
        }
    }

    /// A turn arriving may raise the panel. Anything mid-conversation says no.
    public var allowsAmbientSurface: Bool {
        switch self {
        case .hidden, .idle: return true
        default: return false
        }
    }

    public var isPendingSend: Bool {
        if case .pendingSend = self { return true }
        return false
    }

    /// The reply flow owns the stage from mic-open to resolution. These are the
    /// states a stale repaint must never replace. `.arming` owns it too — the
    /// mic is open — so an explicit dismiss tears it down honestly through
    /// `endCapture` like every other capture state.
    public var ownsStage: Bool {
        switch self {
        case .arming, .listening, .transcribing, .pendingSend: return true
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
    public func admits(_ next: PanelState) -> Bool {
        switch self {
        case .arming:
            switch next {
            // The hold resolved: the arming face upgrades to the live pill.
            case .listening: return true
            // Everything else is refused — an ambient repaint must never
            // stomp the arm window. The abort path does not travel this
            // table at all: revertArming restores the stashed prior state
            // through the restore door, and an explicit dismiss goes
            // through endCapture's user door.
            default: return false
            }
        case .listening:
            switch next {
            case .transcribing, .listening, .result: return true
            default: return false
            }
        case .transcribing:
            switch next {
            // result is the failure path; receipt is the ONE success-shaped
            // card left (ui-pass-7, ruling 5): a delivered dictation says
            // where the words went. Reply-send success still paints nothing.
            case .pendingSend, .listening, .transcribing, .result, .receipt: return true
            default: return false
            }
        case .pendingSend:
            switch next {
            case .result, .transcribing, .listening: return true
            default: return false
            }
        // Everything else admits everything. The old "refuse a late success
        // receipt over live speech" guard died with the Sent face: the
        // dictation receipt can only arrive out of `.transcribing`, its own
        // flow's stage, so it can never paint over live speech.
        case .hidden, .idle, .preparing, .speaking, .result, .receipt, .settings,
             .pastAgents:
            return true
        }
    }
}
