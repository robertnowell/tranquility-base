import Foundation

/// A live process that has not heard a word since it came up.
///
/// Ruled 19 Aug, on a session Robert restarted in front of the panel: *"if we
/// restart an agent and it was mid-process when it got shut down, it's kind of
/// mid tool use. It looks like it's in progress, but it's stuck because I just
/// restarted it. It's waiting on my input. But our detector detects it as idle
/// … when you restart an agent, the lamp should immediately be on."*
///
/// Both witnesses were telling the truth and the panel still got it wrong.
/// `04d50469` was killed between a tool call and its result, so the transcript
/// ends mid-turn and `SessionActivity` reads `working` — correctly, the turn
/// really never closed. `claude agents --json` said `idle` — correctly, the
/// resumed process is sitting at a prompt with nothing in flight. The lamp
/// rule wrote in 18 Aug that the process outranks the file on exactly this
/// disagreement (`working` + `idle` = quiet), because the case it was built
/// for was a turn that HAD ended in a shape the file could not express. This
/// is the other case with the same shape, and quiet sent it to Past Agents:
/// abandoned work, filed away, on the morning its owner restarted it on
/// purpose.
///
/// The fact that separates them is the process's own start time. If it came up
/// AFTER the last word in the conversation, then nothing in that file was
/// written by the process that is running now: the open turn belongs to a
/// process that no longer exists, and no amount of waiting will close it. That
/// is not idleness, it is stranded work, and the only thing that moves it is a
/// human typing. So the lamp goes amber and the row stays on the grid.
///
/// First-hand, like `status: waiting` and unlike a stall: it is not inferred
/// from silence but read from two clocks, both stated outright by the sources
/// that own them. And it retires itself — the moment the session is spoken to,
/// the conversation's last word is newer than the process, and the rule stops
/// matching for good.
public enum AgentRestart {

    /// What the row says next to the amber lamp, and what the hover says in
    /// full. One place, because a lamp and its caption derived separately is
    /// the bug of 18 Aug (`d40f56bc`: right lamp, wrong sentence).
    public static let short = "restarted mid-turn"
    public static let full = """
        This session was restarted while a turn was still open. The work \
        stopped with the process that was killed, and nothing will move until \
        you send it something.
        """

    /// Whether this session's open turn was stranded by a restart.
    ///
    /// - `activity`: the transcript's verdict. Only the two that describe an
    ///   OPEN turn qualify. `idle` means the turn closed before the kill and
    ///   there is nothing stranded — a resumed prompt with a finished
    ///   conversation behind it needs nobody, and lighting it would put every
    ///   terminal anyone ever reopened on the grid for good. `blocked` keeps
    ///   its own words: it is already amber, already on the grid, and the
    ///   error it names is more use to the reader than the restart is.
    /// - `startedAt`: when the PROCESS came up. Nil (a CLI that does not say)
    ///   means the rule cannot fire, which leaves the row exactly as it was.
    /// - `lastWord`: the newest thing the CONVERSATION did — the timestamp of
    ///   the transcript entry the verdict was read from, or the turn boundary
    ///   the hooks recorded, whichever is later. The hook is in here for the
    ///   race #118 named: a prompt is submitted before its line reaches disk,
    ///   and for that second the file alone would still call the session
    ///   stranded when the user has just spoken to it.
    public static func stranded(activity: SessionActivity?,
                                startedAt: Date?, lastWord: Date?) -> Bool {
        switch activity {
        case .working, .stalled: break
        case .blocked, .idle, nil: return false
        }
        guard let startedAt, let lastWord else { return false }
        return startedAt > lastWord
    }

    /// The conversation's newest moment, from the two sources that can date
    /// one. Stated here rather than at each call site so both bands of the
    /// grid — the waiting rows and the lamp rule — ask the same question.
    public static func lastWord(observedAt: Date?,
                                boundary: SessionActivity.TurnBoundary?) -> Date? {
        [observedAt, boundary?.at].compactMap { $0 }.max()
    }
}
