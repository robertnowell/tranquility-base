import AppKit
import TranquilityCore

/// AppDelegate's grid-assembly half -- the menu-bar item's presence check,
/// sessionRowsNow (every live session as a row), lamp/reason derivation,
/// the idle-grid face, and arrival surfacing -- split out of main.swift
/// (App-lane P7, 24 Aug). The pure parts of this are P8's own target
/// (GridAssembler to Core); this pass only moves the file, not the logic.

extension AppDelegate {
    func checkMenuBarPresence() {
        let present: Bool = {
            guard let window = statusItem.button?.window else { return false }
            return window.screen != nil && window.frame.minX >= 0
        }()
        if present != menuBarWasPresent {
            menuBarWasPresent = present
            Permissions.log(present
                ? "menubar: item is on the bar"
                : "menubar: item DROPPED for space — bar is full; ⌘-drag it toward the clock once (position autosaves)")
        }
    }

    /// The grid's rows: every LIVE session is a row (ruled, docs/ws-b-ruling.md —
    /// a turn skipped by ⌃⌥ is a visible row, not an absence). Green when the
    /// session is waiting on you; quiet when it is merely alive. Dead sessions
    /// appear nowhere. Identity is the minted callsign with the project label
    /// (or live session name) as fallback until minted.
    func sessionRowsNow() -> [SessionRow] {
        guard let coordinator else { return [] }
        let waiting = (try? coordinator.waiting()) ?? []
        // One probe serves every row; the name shown is Claude's own (re-ruled
        // 05 Aug — the terminal tab's string, verbatim), callsign as fallback.
        //
        // `uniquingKeysWith:` rather than `uniqueKeysWithValues:`, because the latter
        // TRAPS on a duplicate key and `agents --json` genuinely returns them:
        // `claude --resume <id>` leaves the original process running and adds a second
        // live entry carrying the SAME sessionId. That killed the app twice —
        // 06 Aug 14:35 and 07 Aug 17:39 — the second crash landing eighteen seconds
        // after a resume started. EXC_BREAKPOINT in a refresh timer, so it fires as
        // soon as the duplicate appears and there is no recovery path.
        //
        // First-seen wins, matching the `first(where:)` lookups used on every other
        // path (Coordinator.dispatch among them), so one rule governs everywhere
        // rather than this view resolving collisions differently from dispatch.
        // WHICH duplicate is the right target is a separate, open question — both
        // processes are alive and both answer to the id — so the collision is logged
        // rather than silently settled.
        var liveById: [String: LiveSession] = [:]
        for session in ClaudeAgentsCLI().sessions() ?? [] {
            if let existing = liveById[session.sessionId] {
                Permissions.log("agents: duplicate sessionId \(session.sessionId.prefix(8)) "
                    + "— pids \(existing.pid) and \(session.pid); keeping \(existing.pid)")
                continue
            }
            liveById[session.sessionId] = session
        }
        // Smooth a transient miss in the probe above (see `lastSeenLive`'s
        // doc comment): a session seen live within the grace window but
        // absent from THIS read keeps its last-known entry rather than
        // dropping straight to "closed". Refresh every session this read
        // did find, backfill the ones it briefly lost, then prune anything
        // that has aged out — so a session actually gone still reads gone
        // the moment the window lapses.
        let now = Date()
        for (id, session) in liveById { lastSeenLive[id] = (session, now) }
        for (id, remembered) in lastSeenLive
        where liveById[id] == nil && now.timeIntervalSince(remembered.at) < Self.liveGrace {
            liveById[id] = remembered.session
        }
        lastSeenLive = lastSeenLive.filter { now.timeIntervalSince($0.value.at) < Self.liveGrace }
        // The topic is the stored brief's composed 3–6-word label, carried by
        // the waiting query's brief join — NEVER a prose prefix of summaryText
        // or the raw assistant message (ruled: that derivation produced orphan
        // fragments like "**Voices for lif"). No brief yet = name only.
        // Turn boundaries serve BOTH bands now: waiting() keeps a heard-but-
        // unanswered session in this band, and if the user answered it IN THE
        // TERMINAL the agent is already chewing — green ("you have not
        // answered this") would be a lie, so the transcript's verdict wins.
        let boundaries = (try? store?.latestTurnBoundaries()) ?? [:]
        // The user's own half of the switch, read once for the whole repaint.
        // The OFF half is applied at the bottom of this function, after every
        // band; ON has to travel INTO the lamp rule, because it changes what
        // colour a row is rather than which face draws it.
        let switchedOn = LampSwitch.loadOn()
        var rows = waiting.map { (event: WaitingSession) -> SessionRow in
            let evidence = event.transcriptPath.flatMap {
                SessionActivity.evidence(transcriptPath: $0,
                                         boundary: boundaries[event.sessionId])
            }
            // Blue here means "it is chewing on your last reply". A resumed
            // session is not: the turn the file describes died with the process
            // that wrote it. Green is the truth — you still owe it an answer,
            // and now nothing at all moves until you type one.
            let resumed = AgentRestart.resumed(
                startedAt: liveById[event.sessionId]?.startedAtDate,
                lastWord: AgentRestart.lastWord(observedAt: evidence?.observedAt,
                                                boundary: boundaries[event.sessionId]))
            // Green says "you have not answered this". While a reply to
            // this very turn is in flight that is the most misleading thing
            // the grid can say — the cursor does not advance until the send
            // confirms, so the row goes on asking for the user seconds after
            // they spoke to it. A newer turn arriving still wins: see
            // DeliveryInFlight.supersedesWaiting. A terminal reply wins the
            // same way: the transcript says working, so the row does too.
            // The process outranks the stored turn, on this band too (19 Aug).
            // A session locked at a dialog has not read your last reply and is
            // not about to: green would offer to read out something it said
            // before it was killed, while the only move that helps is in the
            // terminal. See `blockedOnYou` for the case that is always here.
            let blocked = Self.blockedOnYou(liveById[event.sessionId], resumed: resumed)
            return SessionRow(
                id: event.sessionId,
                name: tabDisplayName(for: event, live: liveById[event.sessionId]),
                // The id, not the callsign — ruled 12 Aug, and the same in
                // every band so a row means the same thing wherever it sits.
                // A blocked row spends the column on its reason, like every
                // other amber row on the panel.
                aux: blocked?.reason ?? SessionRow.shortId(event.sessionId),
                lamp: blocked?.lamp
                    ?? (!resumed
                        && (evidence?.activity == .working
                            || delivering.supersedesWaiting(event.sessionId,
                                                            latestId: event.latestId))
                        ? .working : .ready),
                // This band is the only one with a real read state: these
                // rows HAVE a waiting turn. Everywhere else the answer is
                // `.none`, which rests at the same intensity as `.opened`
                // (16 Aug) — an idle session is not asking for you either.
                read: event.heard ? .opened : .unread,
                // And the hover carries the whole sentence, as it does on every
                // other amber row — the column can only hold a clause.
                detail: blocked?.detail)
        }
        // Live sessions with nothing waiting: quiet rows, so a skipped or heard
        // session stays findable. Walked via `known` — already latestId DESC —
        // so the band is recency-ordered like the waiting band above it, never
        // Dictionary.values hash order (which reshuffled between refreshes).
        // (Turn boundaries were computed above the waiting band — see
        // SessionActivity.classify's precedence note: the hooks settle
        // working-vs-idle, which the transcript alone gets wrong 9.8% of the
        // time an agent is working.)
        let waitingIds = Set(waiting.map(\.sessionId))
        let known = (try? store?.allKnownSessions()) ?? []
        // Minted callsigns outlive the process that earned them, so a dead row
        // keeps the name you have been calling it. The store is the only place
        // this exists — nothing on disk records what we named a session.
        let closedCallsigns = Dictionary(
            known.compactMap { row in row.callsign.map { (row.sessionId, $0) } },
            uniquingKeysWith: { first, _ in first })
        var placed = waitingIds
        for stored in known where !placed.contains(stored.sessionId) {
            guard let live = liveById[stored.sessionId] else { continue }
            // Ruled 12 Aug: headless is headless whether it is running or not.
            // Liveness used to hide these by accident — a cron job is gone
            // before anyone looks — but a LONG one is live and got a row, and
            // then vanished on exit instead of joining the closed band. One
            // rule across all four bands now, and it is the same fail-open
            // predicate the announcer uses.
            guard !SessionDiscovery.isHeadless(transcriptPath: stored.transcriptPath)
            else { continue }
            placed.insert(stored.sessionId)
            let evidence = stored.transcriptPath.flatMap {
                SessionActivity.evidence(transcriptPath: $0,
                                         boundary: boundaries[stored.sessionId])
            }
            let storedLamp = lampAndReason(for: evidence, sessionId: stored.sessionId,
                                           live: live,
                                           boundary: boundaries[stored.sessionId],
                                           pickedUp: switchedOn.contains(stored.sessionId))
            rows.append(SessionRow(
                id: stored.sessionId,
                name: tabDisplayName(for: stored, live: live),
                aux: storedLamp.reason ?? SessionRow.shortId(stored.sessionId),
                lamp: storedLamp.lamp, detail: storedLamp.detail))
        }
        // Live sessions with no stored events yet: nothing to rank them by,
        // so they close the live half of the grid.
        for live in liveById.values where !placed.contains(live.sessionId) {
            let path = live.cwd.map {
                TranscriptTitles.defaultPath(cwd: $0, sessionId: live.sessionId)
            }
            // A session with no stored events has no recorded transcript path,
            // so this is the one band that has to derive one. `defaultPath`
            // rebuilds it from the two fields the agents API supplies, and an
            // unreadable path fails open exactly like everywhere else.
            guard !SessionDiscovery.isHeadless(transcriptPath: path) else { continue }
            placed.insert(live.sessionId)
            let evidence = path.flatMap {
                SessionActivity.evidence(transcriptPath: $0,
                                         boundary: boundaries[live.sessionId])
            }
            let liveLamp = lampAndReason(for: evidence, sessionId: live.sessionId,
                                         live: live,
                                         boundary: boundaries[live.sessionId],
                                         pickedUp: switchedOn.contains(live.sessionId))
            rows.append(SessionRow(
                id: live.sessionId,
                name: SessionRow.displayName(
                    liveName: Self.tabTitle(transcriptPath: nil, live: live),
                    callsign: nil, fallback: "session"),
                aux: liveLamp.reason ?? SessionRow.shortId(live.sessionId),
                lamp: liveLamp.lamp, detail: liveLamp.detail))
        }
        // And the sessions that are not awake (ruled 11 Aug). Everything above
        // this line is enumerated from PROCESSES, which is why a machine
        // restart used to empty the panel; everything below is enumerated from
        // the transcripts on disk, which outlive the process.
        //
        // Deliberately ADDITIVE rather than a replacement of the bands above.
        // The live half already agrees with the store and with the announcer;
        // rebuilding it from disk would give the same rows by a second route,
        // and two routes to one answer is how they start disagreeing. Disk
        // enumerates only the population the process list cannot: the dead.
        for found in (SessionDiscovery.discoverIfScanned()?.sessions ?? [])
        where !placed.contains(found.sessionId) && found.liveness != .live {
            placed.insert(found.sessionId)
            rows.append(SessionRow(
                id: found.sessionId,
                name: SessionRow.displayName(
                    liveName: found.title,
                    callsign: closedCallsigns[found.sessionId],
                    fallback: found.cwd.map { ($0 as NSString).lastPathComponent } ?? "session"),
                // Same precedence as the live band above: a session that died
                // mid-error says why, and otherwise the column carries the id.
                // For a closed row that id is the whole point — it is the
                // thing you would otherwise be grepping ~/.claude/projects for.
                aux: found.activity?.shortReason
                    ?? SessionRow.shortId(found.sessionId),
                lamp: .unlit,
                revivable: found.revivable,
                detail: found.activity?.fullReason))
        }
        // Codex's own history, the same additive shape as the band just
        // above — disk-enumerated, never guessed live (the settled design,
        // 2026-08-21-tb-codex-hand-started-adoption): every row is
        // `.unlit`, exactly what that lamp already means ("no lamp at all —
        // the session exited, or the liveness probe could not say",
        // StateLegend.swift) and precisely what a Codex row's never-guessed
        // liveness is. A separate loop rather than merged into the one
        // above: `discoverCodexIfScanned` never joins a live-process result
        // the way `discoverIfScanned` does (nothing to join — see its own
        // doc comment), so there is no liveness value here to filter
        // `!= .live` against; every row this produces already belongs.
        // `detail` names the harness in the hover rather than the row
        // itself, matching this app's own rule that explanatory text lives
        // in a tooltip, not inline.
        for found in (SessionDiscovery.discoverCodexIfScanned()?.sessions ?? [])
        where !placed.contains(found.sessionId) {
            placed.insert(found.sessionId)
            rows.append(SessionRow(
                id: found.sessionId,
                name: SessionRow.displayName(
                    liveName: found.title,
                    callsign: closedCallsigns[found.sessionId],
                    fallback: found.cwd.map { ($0 as NSString).lastPathComponent } ?? "session"),
                aux: SessionRow.shortId(found.sessionId),
                lamp: .unlit,
                revivable: found.revivable,
                detail: "Codex session"))
        }
        // The user's own switch, applied last and to every band at once.
        //
        // Derived on every repaint rather than stored on the row, so a session
        // that starts waiting stops being filed the moment it does — see
        // `LampSwitch.isOff`, where that exception is the whole policy. And the
        // switch is CLEARED, not merely overridden, when a turn arrives: the
        // file should hold only sessions that are filed right now, or the row
        // would quietly drop off the grid again as soon as the user read it.
        let switchedOff = LampSwitch.load()
        if !switchedOff.isEmpty {
            for row in rows where row.lamp == .ready && switchedOff.contains(row.id) {
                LampSwitch.turnOn(row.id)
                Permissions.log("lamp: \(row.id.prefix(8)) is waiting — switch cleared")
            }
            rows = rows.map { row in
                // A dead session is in the list by liveness already; filing it
                // as well would say the user switched off something that has
                // no lamp to switch.
                guard row.lamp != .unlit,
                      LampSwitch.isOff(row.id, waiting: row.lamp == .ready,
                                       switchedOff: switchedOff)
                else { return row }
                return row.switchedOffCopy()
            }
        }
        // Last, and after every band has been appended: a session that is merely
        // alive drops below the ones doing something, without disturbing the
        // recency order the bands above spent this whole function establishing.
        return SessionRow.quietRowsLast(rows)
    }

    /// The lamp a non-waiting session shows. A waiting session is green by
    /// definition (it has something unread for you) and never reaches here;
    /// this answers the question the grid could not: working, stuck, or just
    /// sitting there. Unreadable transcript = the old quiet lamp, never a
    /// guess.
    ///
    /// A delivery in flight upgrades QUIET to blue, and nothing else. That
    /// precedence is the whole rule, and it is deliberate: green and amber are
    /// the two channels that mean *you* — something unread, or something
    /// stopped — and a reply already on its way is news, not a task. Masking
    /// either of them with advisory blue would spend the one signal the grid
    /// exists to carry, to say something the user just did themselves. Quiet
    /// is the only lamp with nothing to lose, and it is exactly the lamp that
    /// was lying.
    ///
    /// The PROCESS outranks the transcript, and that is the 18 Aug ruling. A
    /// session blocked on a tool prompt — `AskUserQuestion`, a permission
    /// dialog — writes nothing to its transcript, fires no hook, and from the
    /// file alone is indistinguishable from an agent happily running Bash. But
    /// `claude agents --json` has watched the process and says
    /// `status: waiting · waitingFor: input needed`, which the app has read
    /// every five seconds since the beginning and used only to decide whether
    /// it was safe to type into a tab. It is the plainest needs-you signal in
    /// the system and it reached no lamp until now. `busy` and `idle` are read
    /// the same way, for the same reason: the process knows, and the file only
    /// implies.
    ///
    /// A RESTART is the one place that ruling needed a third fact. The process
    /// says idle and is right; the file says working and is right; the session
    /// is standing to anyway, because the two of them are talking about
    /// different processes. `AgentRestart` settles that one, above everything
    /// here except `waiting` and a process that is visibly `busy`.
    ///
    /// The lamp AND the words next to it, decided together.
    ///
    /// One function because they were two, and they disagreed in front of
    /// Robert (18 Aug): `d40f56bc` lit amber correctly — the process reported
    /// `waiting`, it was asking him a question — while the reason column, read
    /// separately from the transcript, said "silent for 2h". Right lamp, wrong
    /// sentence, and the sentence is what he read. A lamp and its caption
    /// derived from two sources is the same class of bug as two sources for
    /// the lamp itself.
    /// The process says it is holding for a human — the lamp half of
    /// `WaitingAt`, which carries the rule and the words.
    ///
    /// Amber, always, and above everything else the lamp rule weighs: this is a
    /// process watched from outside saying it cannot go on alone, and amber's
    /// tap is the one move that helps — it puts you in the terminal. Wired into
    /// every band on 18 Aug EXCEPT the waiting band, whose rows are literally
    /// about needing you and which computed green from stored turns without ever
    /// asking the process. That gap had a permanent occupant; see `WaitingAt`.
    private static func blockedOnYou(_ live: LiveSession?, resumed: Bool)
        -> (lamp: Lamp, reason: String?, detail: String?)? {
        guard let at = WaitingAt.read(status: live?.status,
                                      waitingFor: live?.waitingFor,
                                      resumed: resumed) else { return nil }
        return (.fault, at.short, at.full)
    }

    func lampAndReason(for evidence: SessionActivity.Evidence?, sessionId: String,
                               live: LiveSession?,
                               boundary: SessionActivity.TurnBoundary? = nil,
                               pickedUp: Bool = false)
        -> (lamp: Lamp, reason: String?, detail: String?) {
        let activity = evidence?.activity
        let resumed = AgentRestart.resumed(
            startedAt: live?.startedAtDate,
            lastWord: AgentRestart.lastWord(observedAt: evidence?.observedAt,
                                            boundary: boundary))
        // Blocked on you, said by the process itself, and it outranks everything
        // else here — see `blockedOnYou`.
        if let blocked = Self.blockedOnYou(live, resumed: resumed) { return blocked }
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
        if delivering.isInFlight(sessionId) { return (.working, nil, nil) }
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
    private static func tabTitle(transcriptPath: String?, live: LiveSession?) -> String? {
        let path = transcriptPath ?? live.flatMap { session in
            session.cwd.map {
                TranscriptTitles.defaultPath(cwd: $0, sessionId: session.sessionId)
            }
        }
        let title = path.flatMap { TranscriptTitles.shared.latestTitle(transcriptPath: $0) }
        return title ?? live?.name
    }

    /// EVERY displayed identity for a stored event resolves through here — the
    /// grid rows, the speaking card, the depth-1 why card, the reply target —
    /// so no surface can drift back to the derived slug on its own.
    func tabDisplayName(for event: WaitingSession, live: LiveSession?) -> String {
        SessionRow.displayName(
            liveName: Self.tabTitle(transcriptPath: event.transcriptPath, live: live),
            callsign: event.callsign, fallback: event.projectLabel)
    }

    /// The one route to the idle face: assemble the grid and show it.
    /// The provenance comes from the compiler, not from each caller remembering
    /// to pass one. Twenty-five call sites reach the grid; asking each to label
    /// itself is twenty-five chances to paste the neighbour's string, which is
    /// how they all ended up saying "idle repaint" in the first place.
    func showIdleGrid(note: String? = nil,
                              caller: String = #function, line: Int = #line) {
        hud.showIdle(note: note, rows: sessionRowsNow(),
                     because: "grid from \(caller):\(line)")
    }

    /// Redraw the grid against a liveness answer taken AFTER the kill.
    ///
    /// `sessionRowsNow()` reads the same cached probe as everything else, and
    /// that cache is six seconds deep — long enough that a row for a session the
    /// user has just ended would keep its lamp lit, offer to announce, and read
    /// as a control that ignored a click. Dropping the cache first is the whole
    /// difference between "ended" and "ended, eventually".
    ///
    /// Only ever called with the grid as the destination, so a card the user is
    /// reading is not yanked out from under them: this repaints the face the
    /// right-click happened on.
    func refreshGridAfterTerminate() {
        ClaudeAgentsCLI.invalidate()
        guard case .idle = hud.state else { return }
        showIdleGrid()
    }

    /// Arm the receipt's return (ui-pass-7, ruling 5): the receipt has said
    /// its piece, it holds for the delay, and if the panel is still on it —
    /// no gesture moved it — the grid comes back. ONLY the receipt dwells
    /// this way now: the spoken card stays until a gesture moves it (ruling
    /// 14 reversed, 12 Aug), and the `.receipt`-only guard below is the
    /// backstop — an arm from a speaking path fires into a no-op rather
    /// than yanking a card someone is still reading.
    func scheduleReturnToGrid() {
        returnToGridWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.hud.state {
            case .receipt: break
            default: return
            }
            Permissions.log("return-to-grid: card done, "
                + "no gesture for \(Int(Self.returnToGridDelay))s")
            self.showIdleGrid()
        }
        returnToGridWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.returnToGridDelay,
                                      execute: work)
    }

    func refresh() {
        if !hotkey.isRunning { _ = hotkey.start() }
        rebuildMenu()
        updateTitle()
    }

    var micGranted: Bool { Recorder.microphoneAuthorized() }
    var hotkeyWorking: Bool { hotkey?.isRunning ?? false }

    /// An SF Symbol rather than a text glyph.
    ///
    /// The first version used "◌", which is technically visible and practically
    /// invisible: faint, narrow, and indistinguishable from noise in a crowded menu
    /// bar — and on a notched display a narrow new item can end up behind the notch
    /// entirely. A template image renders at the right weight and is findable.
    func updateTitle() {
        guard let button = statusItem.button else { return }

        // Three states, mapped in the same legend the panel reads from.
        let state: StateLegend.MenuBarState
        if isBusy { state = .busy }
        else if !micGranted || !hotkeyWorking { state = .permissionWarning }
        else { state = .normal }
        let appearance = StateLegend.menuBar(state)

        // The site mark for the states that are ours to name; a system symbol
        // only for the permission warning, which is the app saying it cannot
        // work rather than the roster saying anything.
        let image: NSImage?
        if let symbol = appearance.symbol {
            image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: "Tranquility Base")
            image?.isTemplate = true
        } else {
            image = SiteMark.templateImage(filled: appearance.filled)
            image?.accessibilityDescription = "Tranquility Base"
        }
        button.image = image
        // The annunciator at rest (WS-B, ruled): the waiting count rides next to
        // the symbol, quiet when nothing is. The liveness-filtered count — the
        // same predicate a keypress uses — so a dead session is never counted.
        let count = StateLegend.menuBarCount(waitingNow())
        button.title = button.image == nil
            // Fall back to text if the symbol is unavailable, rather than nothing.
            ? appearance.textFallback + count
            : count
        button.imagePosition = count.isEmpty ? .imageOnly : .imageLeft
        // Logged on change only, so the annunciator is checkable from the log
        // without a per-tick line.
        if count != lastMenuBarCount {
            lastMenuBarCount = count
            Permissions.log("menubar: count=\(count.isEmpty ? "0 (quiet)" : count)")
        }
        button.toolTip = "Tranquility Base. Click for the grid. Tap ⌃⌥ to hear, hold ⌥ to reply"
    }
}
