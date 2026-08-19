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
/// written by the process that is running now: whatever the file describes
/// belongs to a process that no longer exists, and this one has been told
/// nothing at all. That is not idleness. It is an agent standing to, and the
/// only thing that moves it is a human typing.
///
/// **The width of that is the second ruling, the same evening.** The first cut
/// lit only sessions whose TURN was open when they died, on the argument that
/// a conversation resumed after a clean finish strands nothing. Robert
/// overruled it: *"when I restart an agent, it belongs on the grid, so its lamp
/// should be lit. It doesn't mean its lamp should be amber — green, blue or
/// amber depending on the appropriate state. Anytime I click on an agent to
/// resurrect it, it is no longer idle."* So resumption is the membership fact
/// and it does not care what the old turn was doing; the STATE still picks the
/// colour, and this only supplies the colour for the one case nothing else
/// speaks to — a resumed process with nothing in flight and nothing pending,
/// which every other rule reads as quiet.
///
/// First-hand, like `status: waiting` and unlike a stall: it is not inferred
/// from silence but read from two clocks, both stated outright by the sources
/// that own them. And it retires itself — the moment the session is spoken to,
/// the conversation's last word is newer than the process, and the rule stops
/// matching for good.
public enum AgentRestart {

    /// Whether this process came up after the conversation's last word, and so
    /// has been told nothing since it started.
    ///
    /// - `startedAt`: when the PROCESS came up. Nil (a CLI that does not say)
    ///   means the rule cannot fire, which leaves the row exactly as it was.
    /// - `lastWord`: the newest thing the CONVERSATION did — see `lastWord`.
    ///   Nil is an unreadable or empty transcript, and an unreadable file has
    ///   never been allowed to light a lamp here; it is not evidence of a
    ///   restart, it is an absence of evidence about anything.
    public static func resumed(startedAt: Date?, lastWord: Date?) -> Bool {
        guard let startedAt, let lastWord else { return false }
        return startedAt > lastWord
    }

    /// What a resumed session's row says next to its lamp, and what the hover
    /// says in full — or nil when this has nothing to add to the lamp the
    /// state already earned.
    ///
    /// One place, because a lamp and its caption derived separately is the bug
    /// of 18 Aug (`d40f56bc`: right lamp, wrong sentence). Two sentences
    /// rather than one, because the two restarts are not the same news: work
    /// that was interrupted mid-flight is worth more of a nudge than a
    /// conversation somebody reopened, and a row that says "restarted" for
    /// both would make the reader open each one to find out which.
    ///
    /// `blocked` gets nil deliberately: it is already amber, already on the
    /// grid, and the error it names tells the reader more than the restart
    /// does. `working`/`stalled` after a restart is the interrupted case;
    /// `idle` and an unreadable verdict are the reopened one.
    public static func reason(for activity: SessionActivity?)
        -> (short: String, full: String)? {
        switch activity {
        case .blocked: return nil
        case .working, .stalled:
            return ("restarted mid-turn",
                    "This session was restarted while a turn was still open. The work "
                    + "stopped with the process that was killed, and nothing will move "
                    + "until you send it something.")
        case .idle, nil:
            return ("restarted, waiting on you",
                    "This session has been restarted and has heard nothing since. It is "
                    + "standing by for its next instruction.")
        }
    }

    /// The conversation's newest moment, from the two sources that can date
    /// one. Stated here rather than at each call site so both bands of the
    /// grid — the waiting rows and the lamp rule — ask the same question.
    ///
    /// The hook is in here for the race #118 named: a prompt is submitted
    /// before its line reaches disk, and for that second the file alone would
    /// still call the session unspoken-to when the user has just spoken to it.
    public static func lastWord(observedAt: Date?,
                                boundary: SessionActivity.TurnBoundary?) -> Date? {
        [observedAt, boundary?.at].compactMap { $0 }.max()
    }
}
