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
        pickedUp: Bool = false, isInFlight: Bool = false, harness: String? = nil
    ) -> (lamp: Lamp, reason: String?, detail: String?) {
        // The rules moved to `SessionVerdict.resolve` on 01 Sep and did not
        // change: `VerdictAgreesWithTheOldLampTests` drives both this and a copy
        // of the previous body across 540 combinations of every witness, every
        // file state, every boundary and both user flags, and asserts they agree
        // on lamp, reason and detail.
        //
        // What the move buys is not different behaviour. It is that the verdict
        // now NAMES ITS WITNESS, so a wrong lamp is a log line rather than a
        // screenshot; that a witness which never spoke can no longer be mistaken
        // for one that did (see `Testimony`); and that the rules are testable as
        // properties rather than only as examples.
        let resumed = AgentRestart.resumed(
            startedAt: live?.startedAtDate,
            lastWord: AgentRestart.lastWord(observedAt: evidence?.observedAt,
                                            boundary: boundary))
        let verdict = SessionVerdict.resolve(
            process: SessionVerdict.testimony(of: live, harness: harness, resumed: resumed),
            file: evidence.map { Testimony.says($0.activity) } ?? .silent,
            resumed: resumed, pickedUp: pickedUp, isInFlight: isInFlight)
        return (verdict.lamp, verdict.because, verdict.detail)
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
    /// The harness's OWN name for a session is looked up in here rather than
    /// handed in. It used to be a parameter, and a parameter is a thing a call
    /// site can forget: `fb13436` added it, taught one of the four bands that
    /// build a row, and said "every band" in its commit message. Robert saw
    /// "Projects" again the same afternoon. There is no version of this that
    /// survives being remembered at nine call sites, so it is not asked for
    /// any more.
    ///
    /// Needed because `tabTitle` cannot find a Codex name on its own: it reads
    /// a CLAUDE CODE title out of `transcriptPath`, and for a Codex session
    /// that path is a rollout with no such record, so it falls through to
    /// `live?.name` — which only exists if the row came from the live map.
    ///
    /// Ahead of the callsign because for Claude Code `liveName` already IS the
    /// harness's own tab title and Codex's thread name is the same kind of
    /// thing; ahead of `projectLabel` because a directory is the answer of
    /// last resort, and it is the answer Robert kept being shown.
    public static func tabDisplayName(for event: WaitingSession, live: LiveSession?) -> String {
        SessionRow.displayName(
            liveName: tabTitle(transcriptPath: event.transcriptPath, live: live)
                ?? harnessName(event.sessionId),
            callsign: event.callsign, fallback: event.projectLabel)
    }

    /// The same name, for a row built from a LIVE session with no stored event
    /// behind it — the band that used to fall back to the literal "session".
    public static func tabDisplayName(live: LiveSession, callsign: String?) -> String {
        SessionRow.displayName(
            liveName: tabTitle(transcriptPath: nil, live: live)
                ?? harnessName(live.sessionId),
            callsign: callsign, fallback: "session")
    }

    /// And for a row built from DISK, where the title comes from discovery.
    public static func tabDisplayName(discovered title: String?, sessionId: String,
                                      callsign: String?, cwd: String?) -> String {
        SessionRow.displayName(
            liveName: title ?? harnessName(sessionId),
            callsign: callsign,
            fallback: cwd.map { ($0 as NSString).lastPathComponent } ?? "session")
    }

    /// What the harness itself calls this session, for a harness that keeps a
    /// name of its own. Codex does, in its thread table; Claude Code's
    /// equivalent is the transcript title `tabTitle` already reads.
    public static func harnessName(_ sessionId: String) -> String? {
        harnessNames()[sessionId.lowercased()]
    }

    /// The seam, for tests and for nothing else. Production never sets it: the
    /// whole point of looking the name up in here is that no caller has to
    /// remember to supply one.
    public nonisolated(unsafe) static var harnessNames: @Sendable () -> [String: String] = {
        CodexThreadNames.all()
    }
}
