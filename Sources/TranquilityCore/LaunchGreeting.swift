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
    /// `voice` is the voice the greeting was SPOKEN in, bound to the session
    /// here so everything it says afterwards is the same person. The launcher
    /// peeked at the rotation before it spoke; this is where that peek becomes
    /// the assignment.
    @discardableResult
    public static func record(
        sessionId: String, directory: String, line: String, voice: String? = nil,
        tty: String? = nil, store: QueueStore, at: Date = Date(),
        projects: URL = TranscriptArchive.projectsDirectory
    ) throws -> Int64? {
        if let voice { try store.assignVoice(voice, to: sessionId, at: at) }
        let event = QueuedEvent(
            createdAtMs: Int64(at.timeIntervalSince1970 * 1000),
            hookEvent: .stop,
            sessionId: sessionId,
            promptId: "greeting:\(sessionId)",
            cwd: directory,
            // The transcript, found by session id.
            //
            // This was nil, with a comment reasoning that the two readers of the
            // field both do the right thing with nothing — the headless filter
            // fails open, and a turn that has not happened has no ladder rungs
            // to walk. Both true, and both beside the point: there is a THIRD
            // reader, and it is the one that matters. Delivery is confirmed by
            // watching our own text appear in the transcript, so an event with
            // no transcript cannot be confirmed, and the first reply to a new
            // agent — the entire feature — landed correctly and then reported
            // "typed it into Projects, but couldn't confirm it landed."
            //
            // Still nil-tolerant everywhere: a session registers a beat before
            // its first line hits disk, so this can legitimately come back
            // empty, and `Coordinator.dispatch` resolves it again at send time
            // rather than trusting a row written seconds earlier.
            transcriptPath: TranscriptArchive.transcriptPath(forSessionId: sessionId,
                                                             projects: projects),
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
        screen: (() -> String?)? = nil,
        quietFloor: TimeInterval = 12,
        stillThreshold: Int = 3,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> String? {
        let started = now()
        let deadline = started.addingTimeInterval(timeout)
        var lastScreen: String?
        var unchanged = 0
        while now() < deadline {
            // nil means the probe could not answer, which is not the same as
            // "not registered yet" — keep waiting rather than concluding.
            if let live = agents.sessions(),
               let fresh = live.first(where: {
                   $0.cwd == directory && !known.contains($0.sessionId)
               }) {
                return fresh.sessionId
            }
            // A pane that has STOPPED does not need the rest of the budget.
            //
            // Measured 3 Sep on this machine: a healthy launch registers in
            // about seven seconds, and the full timeout is thirty. That gap
            // used to be paid in full by every blocked launch, because the
            // only early exit here was success. Robert, on watching it:
            // "why is it 30 … 15 seems reasonable".
            //
            // The fast detector already existed — `TrustPromptWatcher`'s
            // `stuckThreshold`, which notices that a TUI has stopped
            // redrawing — but it never fires for this harness, because the
            // settled-banner needle claims victory first. So the same idea
            // lives here too, where it does not depend on recognising
            // anything: a screen that has not changed, while nothing has
            // registered, is a screen waiting on a human.
            //
            // The floor is the safety. Below it nothing concludes, however
            // still the pane looks, so a healthy launch that has drawn its
            // composer and is a beat behind on registering is never called
            // stuck. Above it, three identical reads end the wait. Blocked
            // launches surface at roughly the floor; healthy ones are
            // untouched, because they have already returned.
            //
            // Costs nothing when `screen` is nil, which is every caller that
            // has no pane to read (tests, and the Codex twin below).
            if let screen, now().timeIntervalSince(started) >= quietFloor {
                let text = screen()
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if text == lastScreen { unchanged += 1 } else { unchanged = 1 }
                    lastScreen = text
                    if unchanged >= stillThreshold { return nil }
                } else {
                    // Unreadable is not evidence of anything. Do not let a
                    // failed capture accumulate toward a verdict.
                    lastScreen = nil
                    unchanged = 0
                }
            }
            sleep(interval)
        }
        return nil
    }

    /// `awaitRegistration`'s Codex twin — and NOT what its first version
    /// (24 Aug) did. That version polled `SessionDiscovery.discoverCodex`,
    /// which reads the rollout file Codex writes in `~/.codex/sessions` —
    /// and found live, 26 Aug, chasing a launch that greeted, then never
    /// registered: Codex does not write that file until the FIRST TURN
    /// COMPLETES. A fresh launch with nobody talked to yet has no rollout to
    /// discover, ever — the wait timed out at 30s on every single Codex
    /// launch, silently, because "no session in this repo has finished a
    /// turn yet" is not "not registered," and the code could not tell them
    /// apart.
    ///
    /// `CodexRollout.threadWriterLocksDirectory` is the fix: Codex writes an
    /// empty `<threadId>.lock` there the moment the thread is CREATED, no
    /// turn required — confirmed live by launching a bare, message-less
    /// `codex` and watching the lock appear within the same second, well
    /// before any rollout exists. No `cwd` in a lock's filename, so this
    /// cannot filter by directory the way the Claude Code and old-Codex
    /// versions both could — `liveThreadIds`'s own doc comment says why
    /// that's an accepted trade, not an oversight. Interval drops to 0.5s:
    /// a directory listing plus per-file mtime stat is far cheaper than
    /// `discoverCodex`'s full archive walk, and Codex's own lock creation
    /// is near-instant, so there's no reason to wait as long between polls.
    public static func awaitCodexRegistration(
        excluding known: Set<String>,
        liveThreadIds: () -> [String] = { CodexRollout.liveThreadIds() },
        timeout: TimeInterval = 30,
        interval: TimeInterval = 0.5,
        screen: (() -> String?)? = nil,
        quietFloor: TimeInterval = 12,
        stillThreshold: Int = 6,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> String? {
        let started = now()
        let deadline = started.addingTimeInterval(timeout)
        var lastScreen: String?
        var unchanged = 0
        while now() < deadline {
            if let fresh = liveThreadIds().first(where: { !known.contains($0) }) {
                return fresh
            }
            // Parity with the Claude twin above, and for the same reason: a
            // pane that has stopped moving does not need the rest of the
            // budget. Codex is the harness where this matters MORE, not less
            // — its update chooser ("1. Update now") is a screen TB
            // deliberately refuses to answer, so every launch that meets one
            // is a launch that will wait out the whole timeout unless
            // something notices the pane went still. Measured live 3 Sep:
            // codex-cli 0.152.1 with 0.153.2 released, and every fresh pane
            // on this machine stops there.
            //
            // `stillThreshold` is doubled against the Claude path because
            // this loop polls twice as fast; both come to about three seconds
            // of stillness past the floor.
            if let screen, now().timeIntervalSince(started) >= quietFloor {
                let text = screen()
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if text == lastScreen { unchanged += 1 } else { unchanged = 1 }
                    lastScreen = text
                    if unchanged >= stillThreshold { return nil }
                } else {
                    lastScreen = nil
                    unchanged = 0
                }
            }
            sleep(interval)
        }
        return nil
    }
}
