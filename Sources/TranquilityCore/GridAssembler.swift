import Foundation

/// The pure half of assembling a session row's lamp, reason, and displayed
/// name — extracted from the app layer (App-lane P8, 24 Aug,
/// "GridAssembler to Core"). Everything here already depended on nothing
/// but Core types (`WaitingAt`, `AgentRestart`, `SessionActivity`,
/// `TranscriptTitles`, `Lamp`, `SessionRow`) — the app layer was just
/// where it happened to be written.
///
/// What did NOT move, deliberately: `AppDelegate.sessionRowsNow()` itself
/// stays app-side. It reads `coordinator`/`store` (fine, both Core) plus
/// two pieces of AppDelegate's own in-memory state — `lastSeenLive` (the
/// liveness-grace cache) and `delivering` (in-flight deliveries) — that
/// would need a real redesign (a stateful Core type owning that cache,
/// replacing what's currently plain AppDelegate properties) to extract
/// safely. That is a bigger, riskier change than this pass's scope; this
/// pass moves what was genuinely pure without inventing a new stateful
/// abstraction to carry the rest.
public enum GridAssembler {
    /// The process says it is holding for a human — the lamp half of
    /// `WaitingAt`, which carries the rule and the words.
    ///
    /// Amber, always, and above everything else the lamp rule weighs: this
    /// is a process watched from outside saying it cannot go on alone, and
    /// amber's tap is the one move that helps — it puts you in the
    /// terminal. Wired into every band on 18 Aug EXCEPT the waiting band,
    /// whose rows are literally about needing you and which computed
    /// green from stored turns without ever asking the process. That gap
    /// had a permanent occupant; see `WaitingAt`.
    public static func blockedOnYou(_ live: LiveSession?, resumed: Bool)
        -> (lamp: Lamp, reason: String?, detail: String?)? {
        guard let at = WaitingAt.read(status: live?.status,
                                      waitingFor: live?.waitingFor,
                                      resumed: resumed) else { return nil }
        return (.fault, at.short, at.full)
    }

    /// The lamp a non-waiting session shows. A waiting session is green by
    /// definition (it has something unread for you) and never reaches
    /// here; this answers the question the grid could not: working,
    /// stuck, or just sitting there. Unreadable transcript = the old
    /// quiet lamp, never a guess.
    ///
    /// A delivery in flight upgrades QUIET to blue, and nothing else. That
    /// precedence is the whole rule, and it is deliberate: green and amber
    /// are the two channels that mean *you* — something unread, or
    /// something stopped — and a reply already on its way is news, not a
    /// task. Masking either of them with advisory blue would spend the
    /// one signal the grid exists to carry, to say something the user
    /// just did themselves. Quiet is the only lamp with nothing to lose,
    /// and it is exactly the lamp that was lying.
    ///
    /// The PROCESS outranks the transcript, and that is the 18 Aug
    /// ruling. A session blocked on a tool prompt — `AskUserQuestion`, a
    /// permission dialog — writes nothing to its transcript, fires no
    /// hook, and from the file alone is indistinguishable from an agent
    /// happily running Bash. But `claude agents --json` has watched the
    /// process and says `status: waiting · waitingFor: input needed`,
    /// which the app has read every five seconds since the beginning and
    /// used only to decide whether it was safe to type into a tab. It is
    /// the plainest needs-you signal in the system and it reached no lamp
    /// until now. `busy` and `idle` are read the same way, for the same
    /// reason: the process knows, and the file only implies.
    ///
    /// A RESTART is the one place that ruling needed a third fact. The
    /// process says idle and is right; the file says working and is
    /// right; the session is standing to anyway, because the two of them
    /// are talking about different processes. `AgentRestart` settles that
    /// one, above everything here except `waiting` and a process that is
    /// visibly `busy`.
    ///
    /// The lamp AND the words next to it, decided together.
    ///
    /// One function because they were two, and they disagreed in front of
    /// Robert (18 Aug): `d40f56bc` lit amber correctly — the process
    /// reported `waiting`, it was asking him a question — while the
    /// reason column, read separately from the transcript, said "silent
    /// for 2h". Right lamp, wrong sentence, and the sentence is what he
    /// read. A lamp and its caption derived from two sources is the same
    /// class of bug as two sources for the lamp itself.
    ///
    /// `isInFlight` replaces a direct read of `Coordinator`/AppDelegate's
    /// own `DeliveryInFlight` (App-lane P8, 24 Aug) — the caller already
    /// knows whether this session has a delivery in flight and passes the
    /// bool in, which is what let this function move to Core without
    /// carrying app-layer delivery-tracking state along with it.
    public static func lampAndReason(
        for evidence: SessionActivity.Evidence?, sessionId: String,
        live: LiveSession?, boundary: SessionActivity.TurnBoundary? = nil,
        pickedUp: Bool = false, isInFlight: Bool = false
    ) -> (lamp: Lamp, reason: String?, detail: String?) {
        let activity = evidence?.activity
        let resumed = AgentRestart.resumed(
            startedAt: live?.startedAtDate,
            lastWord: AgentRestart.lastWord(observedAt: evidence?.observedAt,
                                            boundary: boundary))
        // Blocked on you, said by the process itself, and it outranks
        // everything else here — see `blockedOnYou`.
        if let blocked = blockedOnYou(live, resumed: resumed) { return blocked }
        // Resumed, and told nothing since: whatever the file describes was
        // written by a process that has since been killed. Ruled 19 Aug — a
        // session you restart is no longer idle and belongs on the grid — so
        // this sits above the two downgrades below, which read a resumed
        // process's brand-new idleness as "nothing here" and filed the row.
        //
        // It supplies the colour ONLY where nothing else does. `busy` first,
        // because a resumed session that is already chewing has simply not
        // written its first line yet, and blue is the true state; `blocked`
        // keeps its own words inside `reason`. See `AgentRestart`.
        if live?.status != "busy", resumed,
           let said = AgentRestart.reason(for: activity) {
            return (.fault, said.short, said.full)
        }
        let observed: (Lamp, String?, String?) = {
            switch activity {
            case .working:
                // The file says a turn is in flight. If the process says it is
                // idle, the turn ended in a shape the file cannot express — an
                // unanswered prompt with no turn-end marker, the 17:19 case.
                // The process is right and it costs nothing to believe it.
                return live?.status == "idle" ? (.running, nil, nil) : (.working, nil, nil)
            // An ERROR is a fact the transcript states outright, and no process
            // status contradicts it: a session sitting on a usage limit is idle
            // by every measure the API has.
            case .blocked: return (.fault, activity?.shortReason, activity?.fullReason)
            // A STALL is an inference from silence, and silence is exactly what
            // a running process can speak to. Measured 18 Aug: `59181c6d` and
            // `b18ebb61` both had a real typed prompt as their last entry and
            // nothing for four hours — a textbook stall by the file — and both
            // reported `idle`. Robert, looking at the same two rows: "in both
            // of these cases, the agent did return."
            case .stalled:
                switch live?.status {
                case "idle": return (.running, nil, nil)
                case "busy": return (.working, nil, nil)
                // No process at all, or a status we do not recognise: the file
                // is the only witness left and it says silence. Amber stands.
                default: return (.fault, activity?.shortReason, activity?.fullReason)
                }
            case .idle, nil:
                // And the mirror: the file has nothing to say, the process says
                // it is chewing. Blue rather than quiet.
                return live?.status == "busy" ? (.working, nil, nil) : (.running, nil, nil)
            }
        }()
        guard observed.0 == .running else { return observed }
        if isInFlight { return (.working, nil, nil) }
        // Last, and only over a lamp that was going out anyway: the user picked
        // this session up. Ruled 19 Aug — *"because it's alive, clicking on it
        // obviously means I want it to be alive. Now it's in the grid."*
        //
        // Deliberately the LOWEST precedence of anything here. Every rule above
        // is a fact about the agent, and none of them may be overwritten by a
        // fact about the user; this speaks for exactly the rows that have
        // nothing of their own to say, which is the only kind the switch was
        // ever pressed on. Amber rather than a lit-but-colourless row, because
        // amber is what this panel calls "your move", and a session standing by
        // with nothing in flight is waiting on precisely one thing.
        guard pickedUp else { return observed }
        return (.fault, "standing by",
                "You switched this session on. It is alive with nothing in flight, "
                + "waiting for what you tell it next.")
    }

    /// The tab's string for a session, or nil while it has none: the
    /// transcript's last ai-title (TranscriptTitles), else the CLI name.
    /// `agents --json`'s name alone is NOT the tab for unnamed sessions —
    /// it is a derived slug ("robertnowell-90") the tab never displays.
    public static func tabTitle(transcriptPath: String?, live: LiveSession?) -> String? {
        let path = transcriptPath ?? live.flatMap { session in
            session.cwd.map {
                TranscriptTitles.defaultPath(cwd: $0, sessionId: session.sessionId)
            }
        }
        let title = path.flatMap { TranscriptTitles.shared.latestTitle(transcriptPath: $0) }
        return title ?? live?.name
    }

    /// EVERY displayed identity for a stored event resolves through here —
    /// the grid rows, the speaking card, the depth-1 why card, the reply
    /// target — so no surface can drift back to the derived slug on its
    /// own.
    /// `harnessName` is the name the HARNESS itself gave this session, for a
    /// harness that keeps one. Codex does, in its own thread table.
    ///
    /// It is a parameter rather than a lookup because Core does not read
    /// Codex's database, and it sits ahead of `projectLabel` because a
    /// directory is the answer of last resort.
    ///
    /// Needed because `tabTitle` cannot find a Codex name on its own: it reads
    /// a CLAUDE CODE title out of `transcriptPath`, and for a Codex session
    /// that path is a rollout with no such record, so it falls through to
    /// `live?.name`. That works for a row built from the live map and not for
    /// one built from a stored event, which is how a session with a perfectly
    /// good name ("Analyze Mirai's September calendar") showed as "Projects"
    /// on 31 Aug. One name reached a row by three different routes and only
    /// two of them had been taught about Codex.
    public static func tabDisplayName(for event: WaitingSession, live: LiveSession?,
                                      harnessName: String? = nil) -> String {
        SessionRow.displayName(
            liveName: tabTitle(transcriptPath: event.transcriptPath, live: live)
                ?? harnessName,
            callsign: event.callsign, fallback: event.projectLabel)
    }
}
