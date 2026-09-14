import Foundation

/// The four bands that decide which agents exist and what state each is in.
///
/// Moved out of `AppDelegate+Grid.swift` on 13 Sep (#381), before a fifth band
/// was added to it. The reason is a measurement rather than a preference:
/// `Sources/TranquilityApp` is 26,801 lines, 43% of the source, and
/// `Package.swift` declares exactly one test target, depending on
/// `TranquilityCore`. **The app layer has no unit tests and no target that
/// could hold one.** Adding a band to an untestable function in the
/// fastest-growing, least-tested half of the codebase makes the worst measured
/// trend worse.
///
/// Row assembly is not interface code. It decides which agents exist and what
/// state each is in, which is domain logic that happened to be written in the
/// view layer because that is where it was first needed. `Coordinator`'s own
/// header states the standard it belongs to: "Deliberately UI-free so it can be
/// driven from `tbase` and from tests exactly as the app drives it, the
/// integration path and the tested path are the same code."
///
/// **Parameters, not ownership** (ruled 13 Sep). Every one of the nine ways the
/// old function reached the world is an input here, and the app keeps the two
/// caches it owns (`lastSeenLive`, `delivering`) and hands them in. The
/// alternative, a stateful Core type owning the liveness-grace cache, is the
/// redesign `GridAssembler`'s own comment declined in August; it is a better
/// long-run shape and it would put a rewrite of liveness smoothing on the
/// critical path to a checkpoint, which is the wrong trade for a two-day task.
///
/// **No band logic changed in the move.** The bodies below are the previous
/// ones, comments included, with their inputs renamed from ambient reads to
/// parameters.
public extension GridAssembler {

    /// Everything the bands read, in one value so a call site cannot supply
    /// seven of nine and compile.
    struct RowInputs {
        /// Sessions with an unanswered turn. `Coordinator.waiting()`.
        public var waiting: [WaitingSession]
        /// Everything the store has ever seen, latestId DESC.
        public var known: [WaitingSession]
        /// Transcripts on disk, which outlive the process.
        public var discovered: [SessionDiscovery.Session]
        /// Already smoothed: see `smoothedLive`.
        public var liveById: [String: LiveSession]
        public var boundaries: [String: SessionActivity.TurnBoundary]
        /// The user's own switch, both halves, read once per repaint.
        public var switchedOff: Set<String>
        public var switchedOn: Set<String>
        /// Reads a transcript. A closure because it touches the filesystem, and
        /// a test that had to lay down real transcripts to assert a lamp would
        /// be testing the filesystem.
        public var evidence: (String, SessionActivity.TurnBoundary?) -> SessionActivity.Evidence?
        /// Fail-open, exactly as `SessionDiscovery.isHeadless` is: an
        /// unreadable path is somebody's session.
        public var isHeadless: (String?) -> Bool
        /// One conversation, one row: the ids Claude Code's left arrow has
        /// chained together.
        public var family: (String) -> [String]
        /// Whether a reply to this very turn is in flight. The app owns
        /// `DeliveryInFlight` and answers this.
        public var supersedesWaiting: (String, Int64) -> Bool
        /// Whether a delivery to this session is in flight at all, which is the
        /// OTHER question `DeliveryInFlight` answers and a different one.
        /// `supersedesWaiting` asks whether a reply supersedes a specific
        /// waiting turn; this asks whether anything is on its way, and it is
        /// what upgrades QUIET to blue in `lampAndReason`. The app's old
        /// wrapper supplied it on bands 2 and 3 and the extraction dropped it
        /// on the first pass, which would have changed a lamp.
        public var isInFlight: (String) -> Bool
        /// Callsigns minted for sessions that are no longer running.
        public var closedCallsigns: [String: String]
        /// **The fifth band: agents that run somewhere else.**
        ///
        /// Passed in exactly like the other four rather than fetched here, and
        /// carrying no hint of how they are driven. There is one kind of thing,
        /// an agent; keystrokes into a terminal are this app's implementation
        /// choice, not a property of the agent, and location does not belong in
        /// the type system.
        public var remote: RemoteAgents

        /// What the poller last saw, in the shape the bands need.
        public struct RemoteAgents {
            public var agents: [AgentSession]
            /// The pending request per agent, for the few that have one.
            public var requests: [AgentSession.ID: PendingRequest]
            /// Which agents have something the user has not read. Comes from
            /// the stored event log, exactly like every local row's green lamp,
            /// rather than from the provider's own opinion.
            public var unread: Set<AgentSession.ID>
            /// Providers that could not be reached, by id, with the reason.
            public var unreachable: [String: String]

            public init(agents: [AgentSession] = [],
                        requests: [AgentSession.ID: PendingRequest] = [:],
                        unread: Set<AgentSession.ID> = [],
                        unreachable: [String: String] = [:]) {
                self.agents = agents
                self.requests = requests
                self.unread = unread
                self.unreachable = unreachable
            }
        }

        public init(
            waiting: [WaitingSession], known: [WaitingSession],
            discovered: [SessionDiscovery.Session], liveById: [String: LiveSession],
            boundaries: [String: SessionActivity.TurnBoundary],
            switchedOff: Set<String>, switchedOn: Set<String>,
            evidence: @escaping (String, SessionActivity.TurnBoundary?)
                -> SessionActivity.Evidence?,
            isHeadless: @escaping (String?) -> Bool,
            family: @escaping (String) -> [String],
            supersedesWaiting: @escaping (String, Int64) -> Bool,
            isInFlight: @escaping (String) -> Bool,
            closedCallsigns: [String: String] = [:],
            remote: RemoteAgents = RemoteAgents()
        ) {
            self.waiting = waiting
            self.known = known
            self.discovered = discovered
            self.liveById = liveById
            self.boundaries = boundaries
            self.switchedOff = switchedOff
            self.switchedOn = switchedOn
            self.evidence = evidence
            self.isHeadless = isHeadless
            self.family = family
            self.supersedesWaiting = supersedesWaiting
            self.isInFlight = isInFlight
            self.closedCallsigns = closedCallsigns
            self.remote = remote
        }
    }

    /// The rows, plus the two things the old function did on its way past that
    /// are writes rather than answers.
    ///
    /// Returned rather than performed, so this function has no side effects at
    /// all and a test can assert the writes without a filesystem. The app
    /// applies them.
    struct RowVerdict {
        public var rows: [SessionRow]
        /// Sessions whose filed lamp must be CLEARED, because a turn arrived
        /// while they were switched off. Cleared rather than merely overridden:
        /// the file should hold only sessions filed right now, or the row would
        /// quietly drop off the grid again as soon as the user read it.
        public var clearSwitches: [String]
        /// Which harness each live row is, recorded so the card can ask the
        /// same question the rows answered and get the same answer.
        public var harnessById: [String: String]
    }

    /// The lamp a bucket draws.
    ///
    /// One mapping, so a remote row and a local row cannot come to mean
    /// different things by the same colour. `unreachable` is the one that did
    /// not exist before remote agents: a provider we cannot reach is not quiet,
    /// and `.running` is the app's existing word for "alive, nothing owed",
    /// which is the closest honest lamp. The row's WORDS carry the difference,
    /// because a colour cannot say "as of four minutes ago".
    static func lamp(for bucket: AgentPresentation) -> Lamp {
        switch bucket {
        case .needsYou: return .fault
        case .unread: return .ready
        case .working: return .working
        case .idle, .unreachable: return .running
        case .done: return .unlit
        }
    }

    /// The clause in the row's own column.
    ///
    /// An amber row spends it on why, like every other amber row on the panel.
    /// A provider that has gone silent says so, because a row that looks calm
    /// while nobody can reach it is the lie the poller exists to prevent.
    static func remoteAux(bucket: AgentPresentation, request: PendingRequest?,
                          silent: String?, id: AgentSession.ID) -> String {
        if let request, !request.asked.isEmpty { return request.asked }
        if silent != nil { return "cannot reach it" }
        switch bucket {
        case .needsYou: return "needs you"
        case .working: return "working"
        case .unread, .idle, .done, .unreachable: return SessionRow.shortId(id)
        }
    }

    /// The hover, which has room for the whole sentence the column could not
    /// hold, and for the provider's own reason when it is unreachable.
    static func remoteDetail(request: PendingRequest?, silent: String?,
                             agent: AgentSession) -> String? {
        if let silent { return "\(agent.provider) could not be reached: \(silent)" }
        guard let request else {
            return agent.repository.map { "\($0) · \(agent.provider)" } ?? agent.provider
        }
        // EVERY question, not just the first. A request can carry several and
        // answering needs all of them; the column shows one clause and this is
        // where the rest lives.
        return request.questions.map(\.asked).filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Smooth a transient miss in the liveness probe.
    ///
    /// A session seen live within the grace window but absent from THIS read
    /// keeps its last-known entry rather than dropping straight to "closed".
    /// Refresh everything this read found, backfill the ones it briefly lost,
    /// then prune anything that has aged out, so a session actually gone still
    /// reads gone the moment the window lapses.
    ///
    /// Pure, and it returns the updated cache rather than mutating one: the app
    /// still owns the storage, which is what let this move without inventing a
    /// stateful Core type to carry it.
    static func smoothedLive(
        found: [LiveSession], remembered: [String: (session: LiveSession, at: Date)],
        now: Date, grace: TimeInterval,
        log: (String) -> Void = { _ in }
    ) -> (live: [String: LiveSession], remembered: [String: (session: LiveSession, at: Date)]) {
        var liveById: [String: LiveSession] = [:]
        for session in found {
            // `uniquingKeysWith` semantics by hand, because the collision is
            // worth a log line rather than a silent resolution. The latter
            // TRAPS on a duplicate key and `agents --json` genuinely returns
            // them: `claude --resume <id>` leaves the original process running
            // and adds a second live entry carrying the SAME sessionId. That
            // killed the app twice, 06 Aug 14:35 and 07 Aug 17:39, the second
            // crash landing eighteen seconds after a resume started.
            //
            // First-seen wins, matching the `first(where:)` lookups used on
            // every other path (Coordinator.dispatch among them), so one rule
            // governs everywhere rather than this view resolving collisions
            // differently from dispatch. WHICH duplicate is the right target is
            // a separate, open question, so the collision is logged rather than
            // silently settled.
            if let existing = liveById[session.sessionId] {
                log("agents: duplicate sessionId \(session.sessionId.prefix(8)) "
                    + "— pids \(existing.pid) and \(session.pid); keeping \(existing.pid)")
                continue
            }
            liveById[session.sessionId] = session
        }
        var cache = remembered
        for (id, session) in liveById { cache[id] = (session, now) }
        for (id, entry) in cache
        where liveById[id] == nil && now.timeIntervalSince(entry.at) < grace {
            liveById[id] = entry.session
        }
        cache = cache.filter { now.timeIntervalSince($0.value.at) < grace }
        return (liveById, cache)
    }

    /// The four bands, in order, and the rules that order them.
    static func rows(_ input: RowInputs) -> RowVerdict {
        let harnessById = input.liveById.reduce(into: [String: String]()) {
            $0[$1.key] = $1.value.harness
        }

        // BAND 1: sessions with an unanswered turn.
        var rows = input.waiting.map { (event: WaitingSession) -> SessionRow in
            let evidence = event.transcriptPath.flatMap {
                input.evidence($0, input.boundaries[event.sessionId])
            }
            // Blue here means "it is chewing on your last reply". A resumed
            // session is not: the turn the file describes died with the process
            // that wrote it. Green is the truth — you still owe it an answer,
            // and now nothing at all moves until you type one.
            let resumed = AgentRestart.resumed(
                startedAt: input.liveById[event.sessionId]?.startedAtDate,
                lastWord: AgentRestart.lastWord(
                    observedAt: evidence?.observedAt,
                    boundary: input.boundaries[event.sessionId]))
            // The process outranks the stored turn, on this band too (19 Aug).
            // A session locked at a dialog has not read your last reply and is
            // not about to: green would offer to read out something it said
            // before it was killed, while the only move that helps is in the
            // terminal.
            let blocked = GridAssembler.blockedOnYou(input.liveById[event.sessionId],
                                                     resumed: resumed)
            // Green says "you have not answered this". While a reply to this
            // very turn is in flight that is the most misleading thing the grid
            // can say — the cursor does not advance until the send confirms, so
            // the row goes on asking for the user seconds after they spoke to
            // it. A newer turn arriving still wins, and so does a terminal
            // reply: the transcript says working, so the row does too.
            return SessionRow(
                id: event.sessionId,
                name: GridAssembler.tabDisplayName(for: event,
                                                   live: input.liveById[event.sessionId]),
                // The id, not the callsign — ruled 12 Aug, and the same in
                // every band so a row means the same thing wherever it sits. A
                // blocked row spends the column on its reason, like every other
                // amber row on the panel.
                aux: blocked?.reason ?? SessionRow.shortId(event.sessionId),
                lamp: blocked?.lamp
                    ?? (!resumed
                        && (evidence?.activity == .working
                            || input.supersedesWaiting(event.sessionId, event.latestId))
                        ? .working : .ready),
                // This band is the only one with a real read state: these rows
                // HAVE a waiting turn. Everywhere else the answer is `.none`,
                // which rests at the same intensity as `.opened` (16 Aug) — an
                // idle session is not asking for you either.
                read: event.heard ? .opened : .unread,
                // The hover carries the whole sentence, as it does on every
                // other amber row — the column can only hold a clause.
                detail: blocked?.detail,
                harness: input.liveById[event.sessionId]?.harness)
        }

        // BAND 2: live sessions with nothing waiting. Quiet rows, so a skipped
        // or heard session stays findable. Walked via `known` — already
        // latestId DESC — so the band is recency-ordered like the one above it,
        // never Dictionary.values hash order, which reshuffled between
        // refreshes.
        var placed = Set(input.waiting.map(\.sessionId))
        for stored in input.known where !placed.contains(stored.sessionId) {
            guard let live = input.liveById[stored.sessionId] else { continue }
            // Ruled 12 Aug: headless is headless whether it is running or not.
            // Liveness used to hide these by accident — a cron job is gone
            // before anyone looks — but a LONG one is live and got a row, and
            // then vanished on exit instead of joining the closed band. One
            // rule across all four bands now, and it is the same fail-open
            // predicate the announcer uses.
            guard !input.isHeadless(stored.transcriptPath) else { continue }
            placed.insert(stored.sessionId)
            let evidence = stored.transcriptPath.flatMap {
                input.evidence($0, input.boundaries[stored.sessionId])
            }
            let storedLamp = GridAssembler.lampAndReason(
                for: evidence, sessionId: stored.sessionId, live: live,
                boundary: input.boundaries[stored.sessionId],
                pickedUp: input.switchedOn.contains(stored.sessionId),
                isInFlight: input.isInFlight(stored.sessionId))
            rows.append(SessionRow(
                id: stored.sessionId,
                name: GridAssembler.tabDisplayName(for: stored, live: live),
                aux: storedLamp.reason ?? SessionRow.shortId(stored.sessionId),
                lamp: storedLamp.lamp, detail: storedLamp.detail, harness: live.harness))
        }

        // BAND 3: live sessions with no stored events yet. Nothing to rank them
        // by, so they close the live half of the grid.
        for live in input.liveById.values where !placed.contains(live.sessionId) {
            let path = live.cwd.map {
                TranscriptTitles.defaultPath(cwd: $0, sessionId: live.sessionId)
            }
            // A session with no stored events has no recorded transcript path,
            // so this is the one band that has to derive one. `defaultPath`
            // rebuilds it from the two fields the agents API supplies, and an
            // unreadable path fails open exactly like everywhere else.
            guard !input.isHeadless(path) else { continue }
            placed.insert(live.sessionId)
            let evidence = path.flatMap { input.evidence($0, input.boundaries[live.sessionId]) }
            let liveLamp = GridAssembler.lampAndReason(
                for: evidence, sessionId: live.sessionId, live: live,
                boundary: input.boundaries[live.sessionId],
                pickedUp: input.switchedOn.contains(live.sessionId),
                isInFlight: input.isInFlight(live.sessionId))
            rows.append(SessionRow(
                id: live.sessionId,
                name: GridAssembler.tabDisplayName(live: live, callsign: nil),
                aux: liveLamp.reason ?? SessionRow.shortId(live.sessionId),
                lamp: liveLamp.lamp, detail: liveLamp.detail, harness: live.harness))
        }

        // BAND 4: the sessions that are not awake (ruled 11 Aug). Everything
        // above this line is enumerated from PROCESSES, which is why a machine
        // restart used to empty the panel; everything below is enumerated from
        // the transcripts on disk, which outlive the process.
        //
        // Deliberately ADDITIVE rather than a replacement of the bands above.
        // The live half already agrees with the store and with the announcer;
        // rebuilding it from disk would give the same rows by a second route,
        // and two routes to one answer is how they start disagreeing. Disk
        // enumerates only the population the process list cannot: the dead.
        for found in input.discovered
        where !placed.contains(found.sessionId) && found.liveness != .live {
            placed.insert(found.sessionId)
            // One conversation, one row (ruled 10 Sep). A session Claude Code
            // continued under a new id (the left arrow does this) is the same
            // agent; when any other member of its family already has a row,
            // this transcript is that agent's earlier or later half, not a
            // second agent with the same name.
            if input.family(found.sessionId)
                .contains(where: { $0 != found.sessionId && placed.contains($0) }) {
                continue
            }
            rows.append(SessionRow(
                id: found.sessionId,
                name: GridAssembler.tabDisplayName(
                    discovered: found.title, sessionId: found.sessionId,
                    callsign: input.closedCallsigns[found.sessionId], cwd: found.cwd),
                // Same precedence as the live band above: a session that died
                // mid-error says why, and otherwise the column carries the id.
                // For a closed row that id is the whole point — it is the thing
                // you would otherwise be grepping ~/.claude/projects for.
                aux: found.activity?.shortReason ?? SessionRow.shortId(found.sessionId),
                lamp: .unlit,
                revivable: found.revivable,
                // The harness names itself in the hover when it is not the
                // default one, matching this app's rule that explanatory text
                // lives in a tooltip rather than inline. Codex used to get a
                // whole second band for this line.
                detail: found.activity?.fullReason
                    ?? (found.harness == CodexAdapter().id ? "Codex session" : nil),
                harness: found.harness))
        }

        // BAND 5: agents running somewhere else.
        //
        // Placed after the local bands and before the switch, so a remote row
        // is subject to every rule the others are: the user's filed lamp, the
        // quiet-rows-last ordering, all of it. That is the whole claim of this
        // issue, and the placement is the proof: there is no branch below this
        // point that asks whether a row is remote.
        //
        // `lampAndReason` is NOT called here, deliberately. It reads a
        // transcript and a process witness, and a remote agent has neither; its
        // provider states what it is doing, first-hand, which is better
        // evidence than either. `AgentPresentation` is the equivalent rule and
        // it was written for exactly this.
        for agent in input.remote.agents where !placed.contains(agent.id) {
            placed.insert(agent.id)
            let request = input.remote.requests[agent.id]
            let bucket = AgentPresentation.bucket(
                state: agent.state,
                hasPendingRequest: request != nil,
                hasUnread: input.remote.unread.contains(agent.id))
            let silent = input.remote.unreachable[agent.provider]
            rows.append(SessionRow(
                id: agent.id,
                // The provider's own title, then the repository, then the id.
                // Same precedence as every other band: the harness's own name
                // for a thing beats anything this app can derive.
                name: SessionRow.displayName(
                    liveName: agent.title.isEmpty ? nil : agent.title,
                    callsign: agent.repository,
                    fallback: SessionRow.shortId(agent.id)),
                aux: Self.remoteAux(bucket: bucket, request: request, silent: silent,
                                    id: agent.id),
                lamp: Self.lamp(for: bucket),
                // A remote agent cannot be revived by relaunching a command;
                // whether it can be restarted at all is its provider's
                // business, and `Capabilities` answers that where it matters.
                revivable: false,
                read: bucket == .unread ? .unread : .none,
                detail: Self.remoteDetail(request: request, silent: silent, agent: agent),
                harness: agent.provider,
                // The provider said where this agent lives, or said it lives
                // nowhere you can open. Either way the row carries the answer
                // and nothing downstream asks what kind of agent it is.
                door: agent.url.map { .page($0) } ?? SessionRow.Door.none))
        }

        // The user's own switch, applied last and to every band at once.
        //
        // Derived on every repaint rather than stored on the row, so a session
        // that starts waiting stops being filed the moment it does — see
        // `LampSwitch.isOff`, where that exception is the whole policy.
        var clear: [String] = []
        if !input.switchedOff.isEmpty {
            for row in rows where row.lamp == .ready && input.switchedOff.contains(row.id) {
                clear.append(row.id)
            }
            rows = rows.map { row in
                // A dead session is in the list by liveness already; filing it
                // as well would say the user switched off something that has no
                // lamp to switch.
                guard row.lamp != .unlit,
                      LampSwitch.isOff(row.id, waiting: row.lamp == .ready,
                                       switchedOff: input.switchedOff)
                else { return row }
                return row.switchedOffCopy()
            }
        }

        // Last, and after every band has been appended: a session that is
        // merely alive drops below the ones doing something, without disturbing
        // the recency order the bands above spent this whole function
        // establishing.
        return RowVerdict(rows: SessionRow.quietRowsLast(rows),
                          clearSwitches: clear, harnessById: harnessById)
    }
}
