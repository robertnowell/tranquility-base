import Foundation

/// The turn a new agent arrives holding, so that starting one does not begin
/// with a trip to the terminal.
///
/// Ruled 18 Aug. `+ NEW AGENT` opened a Terminal window and stopped there: the
/// grid grew a row the moment the session registered, and the row had nothing
/// to say, because nothing had happened yet. Every other way into this app is
/// voice — you hear what an agent concluded and you answer out loud — and the
/// one moment where you always know what you want to say was the moment that
/// sent you to a keyboard in another window.
///
/// So a launch is a turn. Re-ruled the same afternoon, after the first version
/// went through the announcement pipeline and made you wait for it: **the card
/// comes first**. The panel paints the question and speaks it the instant you
/// press the button, before Terminal has done anything, and the session it
/// belongs to is attached underneath a second or two later when Claude Code
/// registers it. What you say back is typed into the tab as that session's first
/// user message.
///
/// **The greeting is never sent to the agent.** It is the app speaking on its
/// own behalf about a session it just started; the transcript stays empty until
/// you answer, and the answer is the first thing in it. This is the whole reason
/// there is no shadow session, no second store, and no synthetic transcript to
/// keep in agreement with a real one — a greeting is one row in the events table
/// and one row in the brief table, which is what every other turn already is.
public enum LaunchGreeting {

    /// What it says, and it is the whole card.
    ///
    /// Two lines, alternating, because one line said twenty times a day is a
    /// recording and two is a person. Both are the same question asked the two
    /// ways it gets asked, and both are under four seconds of audio — the first
    /// version ("New agent. It's up in Projects and hasn't been asked for
    /// anything. How would you like to get started?") narrated facts you could
    /// already see on the card you were looking at, in front of the only part
    /// that was a question.
    ///
    /// No attribution, no callsign, no project label. You pressed the button;
    /// you know which agent this is, and nothing else here has a name yet.
    public static let lines = [
        "How should we get started?",
        "What would you like to work on?",
    ]

    /// The next line to use. In memory on purpose: the alternation exists so
    /// two launches in a row do not sound identical, and that is a fact about
    /// this sitting, not one worth a file on disk.
    public static func nextLine() -> String { lines[turn.next() % lines.count] }

    private static let turn = Turn()

    final class Turn: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            defer { n += 1 }
            return n
        }
    }

    /// Tags the brief's provenance in the store. Not a model provider, and it
    /// must never be mistaken for one — this brief was authored here, and the
    /// `+stored` suffix the restore path adds makes that legible in the log.
    public static let provider = "greeting"

    /// The card, and — through `recap` — the spoken line, exactly.
    ///
    /// `recap` rather than `topic` + `happened` + `question`: `spokenText()`
    /// prefers an authored recap and assembles the fields only as a fallback,
    /// so this is how a brief says "these words, in this order, and nothing
    /// else". The structured fields still carry the same sentence for the card
    /// and the hub, which read fields rather than the spoken line.
    public static func brief(line: String) -> SessionBrief {
        SessionBrief(topic: "New agent", happened: line, recap: line)
    }

    /// Record the greeting for a session that has just registered.
    ///
    /// `sessionId` is the REAL id Claude Code minted, which is why this is
    /// called after registration rather than at launch: a turn belongs to a
    /// session, and inventing an id here would be the shadow session this design
    /// exists to avoid. Everything downstream — the grid row, the lamp, the
    /// callsign, the reply target, supersession by the session's first real turn
    /// — then addresses the same session the terminal tab does.
    ///
    /// No callsign, and no attribution at all. Minting happens at a session's
    /// first successful summary and freezes for life; a name derived from a turn
    /// with no content is a name derived from nothing — "why is there a callsign?
    /// You don't even know what we're working on." The card the panel paints
    /// carries the DIRECTORY as its title and the question as its body, and the
    /// spoken line is the question alone.
    ///
    /// Idempotent through `promptId`: the launch that produced it is the prompt
    /// this turn answers, so a second call for the same session writes nothing.
    @discardableResult
    public static func record(
        sessionId: String, directory: String, line: String, tty: String? = nil,
        store: QueueStore, at: Date = Date()
    ) throws -> Int64? {
        let event = QueuedEvent(
            createdAtMs: Int64(at.timeIntervalSince1970 * 1000),
            hookEvent: .stop,
            sessionId: sessionId,
            promptId: "greeting:\(sessionId)",
            cwd: directory,
            // No transcript path. The file exists but has nothing in it yet, and
            // the two readers of this field — the headless filter and the ladder
            // — both do the right thing with nil: the filter fails open, and
            // there are no rungs to walk on a turn that has not happened.
            transcriptPath: nil,
            tty: tty)
        return try store.insert(event: event, brief: brief(line: line),
                                provider: provider, at: at)
    }

    /// Wait for the session a launch just started to register itself.
    ///
    /// There is no callback from Claude Code and no id in the launch: a new
    /// session appears in `claude agents --json` a beat after its process comes
    /// up — longer if it is holding a directory-trust prompt, and never if that
    /// prompt is never answered. So the launcher watches the directory it
    /// launched into and takes the first id that was not there before.
    ///
    /// Polls rather than sleeps once, because the wait is a few seconds in the
    /// common case and a walked-away launch must not pay the whole timeout to
    /// find that out. Blocking and subprocess-driven — call off-main, like
    /// everything else that talks to the CLI.
    public static func awaitRegistration(
        directory: String,
        excluding known: Set<String>,
        agents: any ClaudeAgentsReading = ClaudeAgentsCLI(),
        timeout: TimeInterval = 30,
        interval: TimeInterval = 1,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> String? {
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            // nil means the probe could not answer, which is not the same as
            // "not registered yet" — keep waiting rather than concluding.
            if let live = agents.sessions(),
               let fresh = live.first(where: {
                   $0.cwd == directory && !known.contains($0.sessionId)
               }) {
                return fresh.sessionId
            }
            sleep(interval)
        }
        return nil
    }
}
