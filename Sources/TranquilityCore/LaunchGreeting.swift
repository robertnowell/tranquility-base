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
/// So a launch is a turn. The app writes one, in the agent's own name, and the
/// entire loop downstream is the one that already exists: the card appears, the
/// hail sounds, ⌃⌥ reads it, and what you say back is typed into the tab as
/// that session's first user message.
///
/// **The greeting is never sent to the agent.** It is the app speaking on its
/// own behalf about a session it just started; the transcript stays empty until
/// you answer, and the answer is the first thing in it. This is the whole reason
/// there is no shadow session, no second store, and no synthetic transcript to
/// keep in agreement with a real one — a greeting is one row in the events table
/// and one row in the brief table, which is what every other turn already is.
public enum LaunchGreeting {

    /// The one sentence the app says on its own behalf.
    ///
    /// A question, not an instruction, and deliberately the emptiest one there
    /// is: the app knows a session started and knows nothing else, so anything
    /// more specific would be the app guessing at your work out loud.
    public static let question = "How would you like to get started?"

    /// Tags the brief's provenance in the store. Not a model provider, and it
    /// must never be mistaken for one — this brief was authored here, and the
    /// `+stored` suffix the restore path adds makes that legible in the log.
    public static let provider = "greeting"

    /// What the card says and what ⌃⌥ reads out.
    ///
    /// `question`, not `nextStep`: a question outranks a next step in the spoken
    /// composition because it blocks, and this one does — the agent will sit in
    /// its tab doing nothing at all until it is answered.
    public static func brief(directory: String) -> SessionBrief {
        let label = (directory as NSString).lastPathComponent
        return SessionBrief(
            topic: "New agent",
            happened: "It's up in \(label.isEmpty ? directory : label) and hasn't been asked for anything",
            question: question)
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
    /// The callsign is left unminted on purpose. Minting happens at a session's
    /// first successful summary and freezes for life; a name derived from a turn
    /// with no content would be a name derived from nothing. Until then the
    /// greeting is attributed by its directory word, which is the only true
    /// thing about the session anyway.
    ///
    /// Idempotent through `promptId`: the launch that produced it is the prompt
    /// this turn answers, so a second call for the same session writes nothing.
    @discardableResult
    public static func record(
        sessionId: String, directory: String, tty: String? = nil,
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
        return try store.insert(event: event, brief: brief(directory: directory),
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
        interval: TimeInterval = 2,
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
