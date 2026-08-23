import Foundation

/// What a session that is holding for a human is holding AT.
///
/// `claude agents --json` has always answered the first half of this —
/// `status: waiting` — and the panel has read it since 18 Aug: the plainest
/// needs-you signal in the system, a process watched from outside saying it
/// cannot go on alone. The second half is the `waitingFor` beside it, which
/// nothing read, and the difference between its two values is the difference
/// between a question you can answer from here and a modal you cannot.
///
/// Ruled 19 Aug, on a state that is permanently on this machine. Resuming a
/// large session opens a dialog BEFORE the session starts — *"this session is
/// 7h 1m old and 557.7k tokens … 1. Resume from summary  2. Resume full session
/// as-is"* — and it is locked there until a key is pressed. Robert: *"it happens
/// every single time, and it's locked. But not detectable. You can see it's
/// treated as green, like a ready state."*
///
/// Green was the worst available answer: it says the agent has told you
/// something you have not heard and offers to read it out, when the agent has
/// not started and the only move that helps is in the terminal.
///
/// The resume prompt earns its own sentence by joining two facts rather than by
/// matching any text: a dialog is open, and this process has heard nothing since
/// it came up (`AgentRestart.resumed`). A process that has done nothing cannot
/// have opened a permission prompt or asked a question, so the only dialog it
/// can be sitting at is the one Claude Code shows on the way in.
public enum WaitingAt: Equatable, Sendable {
    /// The agent asked and is holding for an answer. Answerable from the panel:
    /// this is the app's daily loop.
    case question
    /// A tool wants to run, or Claude wants to run something sandboxed, or a
    /// worker is asking for something — `permission prompt` / `sandbox
    /// request` / `worker request`, the three OTHER documented `waitingFor`
    /// values added 23 Aug. A structural yes/no gate, not a question: ACP's
    /// spec draws exactly this line between `session/request_permission` and
    /// `elicitation/create` ("permission requests are fundamentally security
    /// decisions"), reached independently from the transport-report research.
    /// NOT answerable from here, same reason `.dialog` is not: a voice
    /// transcript typed at a yes/no gate does not mean what it means at a
    /// free-text question.
    case permission
    /// A modal is open in the terminal. NOT answerable from here — typed text
    /// answers the modal rather than reaching the prompt, which is why
    /// `Readiness.canDispatch` refuses it.
    case dialog
    /// A modal on a process that has not heard a word yet: the resume prompt.
    case resumePrompt

    /// Nil when the process is not waiting at all. Takes the two CLI fields and
    /// the one fact the CLI cannot supply, so every caller classifies the same
    /// way from the same evidence.
    ///
    /// Every value NOT recognized here — `input needed` (the fifth documented
    /// one, genuinely free text) and anything undocumented — falls to
    /// `.question`, deliberately: `Readiness.isDialog`'s own doc comment
    /// states the reasoning this inherits (dispatching only for known-good
    /// values would defer every ordinary reply on the strength of a string
    /// nobody has verified). The three gate values ARE now verified
    /// (2026-08-23-agent-session-transport report, Tier 1), which is what
    /// moved them out of this default and into their own case.
    public static func read(status: String?, waitingFor: String?,
                            resumed: Bool) -> WaitingAt? {
        guard status == "waiting" else { return nil }
        switch waitingFor {
        case Readiness.dialogOpen:
            return resumed ? .resumePrompt : .dialog
        case Readiness.permissionPrompt, Readiness.sandboxRequest, Readiness.workerRequest:
            return .permission
        default:
            return .question
        }
    }

    /// The clause a row shows in its own column.
    public var short: String {
        switch self {
        case .question: return "asking you a question"
        case .permission: return "waiting on a permission"
        case .dialog: return "waiting at a dialog"
        case .resumePrompt: return "waiting at the resume prompt"
        }
    }

    /// The whole sentence, for the hover — the column can only hold a clause,
    /// and until 18 Aug the only place a reason could be READ was the log.
    public var full: String {
        switch self {
        case .question:
            return "The agent has asked you something and is holding for an answer."
        case .permission:
            return "The agent wants permission to run something and is holding for "
                + "a yes or no. That is a decision, not a question — the panel will "
                + "not send a typed reply to it; answer it in the terminal."
        case .dialog:
            return "A dialog is open in this session's terminal and nothing runs "
                + "until it is answered there. Typed replies would answer the dialog "
                + "rather than reach the agent, so the panel will not send to it."
        case .resumePrompt:
            return "Claude Code is asking whether to resume this session from a "
                + "summary or in full. It has not started yet, and nothing will "
                + "happen until you answer it in the terminal."
        }
    }

    /// Whether the panel may type into this session. The one thing all four of
    /// these have in common is that they need the user; only one of them can be
    /// given what it needs from here.
    public var acceptsTypedReply: Bool { self == .question }
}
