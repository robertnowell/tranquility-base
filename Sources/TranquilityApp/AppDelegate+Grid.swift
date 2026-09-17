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
                : "menubar: item DROPPED for space — bar is full; ⌘-drag it toward the clock once (position autosaves)")  // key-names:exempt — diagnostic
        }
    }

    /// The grid's rows: every LIVE session is a row (ruled, docs/ws-b-ruling.md —
    /// a turn skipped by ⌃⌥ is a visible row, not an absence). Green when the
    /// session is waiting on you; quiet when it is merely alive. Dead sessions
    /// appear nowhere. Identity is the minted callsign with the project label
    /// (or live session name) as fallback until minted.
    /// The exit-reason spine. Runs each tick beside the lamp spine: for every
    /// agent that was live last tick and is gone now, read its tmux corpse (if
    /// it left one) for why it died, record it, and reap the corpse. A death
    /// the user asked for disarmed remain-on-exit first and left no corpse, so
    /// it is silently skipped here (see `onTerminateSession` and `postMortem`).
    func observeExits() {
        let liveSessions = (ClaudeAgentsCLI().sessions() ?? [])
            + FileSessionOwnershipStore.shared.liveNonRegistrySessions()
        // Resolve and cache each agent's tmux session name the first time it
        // is seen alive: once it is gone from the registry it can no longer be
        // looked up, so the name has to be captured while it is still here.
        for session in liveSessions where paneNameById[session.sessionId] == nil {
            if let name = TmuxOwnership.pane(
                forSessionId: session.sessionId, pid: session.pid)?.sessionName {
                paneNameById[session.sessionId] = name
            }
        }
        let live = liveSessions.map {
            (id: $0.sessionId, harness: $0.harness, sessionName: paneNameById[$0.sessionId])
        }
        for vanished in exitWatch.observe(live) {
            paneNameById[vanished.id] = nil
            guard let name = vanished.sessionName else { continue }
            let id = vanished.id
            let harness = vanished.harness
            let alive = vanished.secondsAlive
            // tmux blocks, so the read, the record and the reap all go off-main.
            Task.detached {
                guard let postMortem = SessionLauncher.postMortem(session: name) else { return }
                if postMortem.status == "0" {
                    // A clean self-exit (a finished run, a typed `/exit`).
                    // Recorded so the grid's disappearance has a cause, but it
                    // is not a failure and never pages.
                    Track.record("agent_ended", [
                        "agent_id": Track.hash(id), "harness": .token(harness),
                        "outcome": "exited", "via": "left_the_grid",
                        "seconds_alive": .int(alive)])
                } else {
                    // A non-zero exit: a crash, a kill, an update pulling it
                    // down mid-turn. This is the death worth surfacing, and it
                    // rides the same failure path a launch death does, so it
                    // reaches Sentry with the full last line and the Slack
                    // route with the count.
                    let reason = "agent exited (status \(postMortem.status))"
                        + (postMortem.tail.isEmpty ? "" : ": \(postMortem.tail)")
                    Failures.report(.agentExited, reason: reason, harness: harness, session: id)
                }
                // Reap either way: the pane has done its one job, and a corpse
                // left on the socket is a leak.
                Tmux.run(["kill-session", "-t", name], socket: Tmux.socketName)
            }
        }
    }

    /// The four bands moved to Core on 13 Sep (#381, `GridRows.swift`), and
    /// this is what is left: gather the inputs, call it, apply the writes.
    ///
    /// Everything the old body reached for directly is now handed in, which is
    /// the whole of the change. The two pieces of AppDelegate state it owns —
    /// `lastSeenLive`, the liveness-grace cache, and `delivering` — stay here
    /// and are passed as a value and a closure. `GridAssembler`'s August
    /// comment declined this move for exactly that reason, proposing a
    /// stateful Core type to carry them; parameters turned out to be enough,
    /// and they are enough because the bands only ever READ those two.
    func sessionRowsNow() -> [SessionRow] {
        guard let coordinator else { return [] }

        // Codex's own thread names, one read per repaint. A LIVE Codex session
        // never reaches the disk band, which is why two working sessions both
        // showed as "Projects".
        let codexNames = CodexThreadNames.all()
        if codexNames.count != lastCodexNameCount {
            let before = lastCodexNameCount == -1 ? "none yet" : String(lastCodexNameCount)
            Permissions.log("codex names: \(codexNames.count) known (was \(before))")
            lastCodexNameCount = codexNames.count
        }

        // `agents` alone missed a live Codex session at every downstream use of
        // `liveById` (26 Aug): a genuinely running Codex row could be skipped
        // from the grid, or read blockedOnYou wrong, because Codex has no
        // registry of its own to appear in. `liveNonRegistrySessions` adds
        // ownership's own answer for a harness with no registry.
        let found = (ClaudeAgentsCLI().sessions() ?? [])
            + FileSessionOwnershipStore.shared.liveNonRegistrySessions(
                // NO STATUS FOR CODEX, since 01 Sep. This used to say "busy"
                // whenever a prompt had gone in with no Stop after it, which
                // was a compensation for one thing: `SessionActivity` could not
                // read a rollout, so without a hook to lean on the file had
                // nothing to say. It can read one now.
                //
                // The compensation was never sound. "No Stop has come back"
                // fails OPEN — a turn that dies fires no Stop at all — and a
                // `busy` status OUTRANKS the file, so the proxy did not just
                // guess wrong, it silenced the one witness that knew. That is
                // how a turn which died at 01:51 held a blue lamp until the
                // next afternoon.
                //
                // Nothing is lost by staying quiet. Codex writes `task_started`
                // and `task_complete` itself, so its own file answers the
                // question the hooks were introduced to answer, first-hand.
                status: { _ in nil },
                name: { codexNames[$0.lowercased()] })

        let now = Date()
        let smoothed = GridAssembler.smoothedLive(
            found: found, remembered: lastSeenLive, now: now, grace: Self.liveGrace,
            log: { Permissions.log($0) })
        lastSeenLive = smoothed.remembered
        let liveById = smoothed.live

        let boundaries = (try? store?.latestTurnBoundaries()) ?? [:]
        let known = (try? store?.allKnownSessions()) ?? []
        // Minted callsigns outlive the process that earned them, so a dead row
        // keeps the name you have been calling it. The store is the only place
        // this exists — nothing on disk records what we named a session.
        let closedCallsigns = Dictionary(
            known.compactMap { row in row.callsign.map { (row.sessionId, $0) } },
            uniquingKeysWith: { first, _ in first })

        let delivering = self.delivering
        let verdict = GridAssembler.rows(GridAssembler.RowInputs(
            waiting: (try? coordinator.waiting()) ?? [],
            known: known,
            discovered: SessionDiscovery.discoverIfScanned()?.sessions ?? [],
            liveById: liveById,
            boundaries: boundaries,
            switchedOff: LampSwitch.load(),
            switchedOn: LampSwitch.loadOn(),
            evidence: { SessionActivity.evidence(transcriptPath: $0, boundary: $1) },
            isHeadless: { SessionDiscovery.isHeadless(transcriptPath: $0) },
            family: { SessionLineage.family(of: $0) },
            supersedesWaiting: { delivering.supersedesWaiting($0, latestId: $1) },
            isInFlight: { delivering.isInFlight($0) },
            closedCallsigns: closedCallsigns,
            remote: remoteAgents(waiting: (try? coordinator.waiting()) ?? [])))

        // Recorded before anything is drawn so the card can ask the same
        // question the rows answered, and get the same answer.
        harnessById = verdict.harnessById
        // The writes the bands decided but deliberately did not perform: a
        // filed lamp is CLEARED, not merely overridden, when a turn arrives, or
        // the row would quietly drop off the grid again as soon as the user
        // read it.
        for id in verdict.clearSwitches {
            LampSwitch.turnOn(id)
            Permissions.log("lamp: \(id.prefix(8)) is waiting — switch cleared")
        }
        return verdict.rows
    }

    /// See `GridAssembler.tabDisplayName` — this is the thin AppDelegate-side
    /// name for the same call, kept so the many call sites elsewhere in the
    /// app don't all need to say `GridAssembler.` themselves.
    func tabDisplayName(for event: WaitingSession, live: LiveSession?) -> String {
        // A remote agent's name is the provider's title for it, the same
        // name its row wears. The local rule reads a transcript title and
        // falls back to the directory, and a remote agent has no transcript
        // here, so its card said "tranquility-base" over an answer about
        // software markets (Robert, 16 Sep 2:15 PM: "name on card incorrect").
        if let agent = agents?.snapshot.agent(event.sessionId), !agent.title.isEmpty {
            return agent.title
        }
        return GridAssembler.tabDisplayName(for: event, live: live)
    }

    /// The one route to the idle face: assemble the grid and show it.
    /// The provenance comes from the compiler, not from each caller remembering
    /// to pass one. Twenty-five call sites reach the grid; asking each to label
    /// itself is twenty-five chances to paste the neighbour's string, which is
    /// how they all ended up saying "idle repaint" in the first place.
    /// The fifth band's inputs, from whatever the poller last saw.
    ///
    /// Empty on a machine with no provider configured, which draws no remote
    /// rows and costs nothing. Read from the snapshot rather than fetched:
    /// a repaint must never wait on a network call, which is the same rule
    /// `lastSeenLive` follows for the local bands.
    func remoteAgents(waiting: [WaitingSession]) -> GridAssembler.RowInputs.RemoteAgents {
        guard let snapshot = agents?.snapshot else { return .init() }
        return Self.remoteAgents(snapshot: snapshot, waiting: waiting)
    }

    /// The pure half, so the panel's own drill can drive it with a posed
    /// snapshot and a temporary store's waiting list, exactly as the grid
    /// does with the real ones.
    static func remoteAgents(snapshot: AgentPoller.Snapshot,
                             waiting: [WaitingSession]) -> GridAssembler.RowInputs.RemoteAgents {
        // UNREAD COMES FROM THE STORED EVENT LOG, exactly like every local
        // row's green lamp, rather than from the provider's own opinion. The
        // spool line a remote turn wrote is what puts it here, so a remote
        // agent goes green by the same route a local one does.
        //
        // From the WAITING list, which joins the heard cursor. This read
        // `allKnownSessions()`, which does not, so `heard` was nil for every
        // row and every remote row stayed unread for ever, however many times
        // it was heard (Robert, 15 Sep: "read state isn't updating"). A
        // dismissed session is not in the waiting list at all, which is also
        // right: dismissed is read.
        let unread = Set(waiting.filter { !$0.heard }.map(\.sessionId))
        let heard = Set(waiting.filter { $0.heard }.map(\.sessionId))
        let ids = Set(snapshot.agents.map(\.id))
        return .init(agents: snapshot.agents,
                     requests: snapshot.requests,
                     unread: unread.intersection(ids),
                     unreachable: snapshot.unreachable,
                     heard: heard.intersection(ids))
    }

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
        // Gated on the permission actually being active, not attempted
        // unconditionally: `hotkey.start()` calls `CGEvent.tapCreate`,
        // which pops its OWN Input Monitoring consent dialog as a side
        // effect of merely creating the tap. That is a SEPARATE system
        // prompt from the checklist's own Grant button
        // (`Permissions.request(.inputMonitoring)`, `CGRequestListenEventAccess()`),
        // and `refresh()` runs at launch before the user has clicked
        // anything, so it fired regardless of whether they had asked for
        // it. Reported directly, 26 Aug, the same complaint as the
        // microphone instance of this bug ("it shouldn't ask for any
        // permissions before the user clicks grant"), caught live via the
        // isolated test build's own screenshot: a "Keystroke Receiving"
        // dialog sitting over a checklist that had just, correctly,
        // stopped the microphone from doing the same thing.
        //
        // Gate on the RECORDED grant, never on `.active`.
        //
        // `.active` for Input Monitoring means "granted AND the tap is
        // delivering right now" — `state(_:)` asks `listeningProbe`, and that
        // probe is `hotkey.isListening`. Gating the START of the tap on it
        // makes a circle the app cannot leave: the tap will not start until it
        // is listening, and it cannot listen until it starts.
        //
        // Live consequence, 26 Aug: Input Monitoring stuck on "granted,
        // restart to finish" forever, the hotkeys dead, and every restart
        // landing on the same screen — Robert restarted by hand and it changed
        // nothing, because no number of restarts can satisfy a condition that
        // depends on the thing it is blocking.
        //
        // `isGranted` is the right question and keeps the reason the gate was
        // added at all (18:12 today): `CGPreflightListenEventAccess()` is false
        // until the permission is granted, so the tap is still never created
        // speculatively and `tapCreate` still never pops its own dialog. It
        // just does not also require the outcome as its own precondition.
        if !hotkey.isRunning, Permissions.isGranted(.inputMonitoring) {
            _ = hotkey.start()
        }
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
                            accessibilityDescription: AppIdentity.displayName)
            image?.isTemplate = true
        } else {
            image = SiteMark.templateImage(
                filled: appearance.filled,
                developmentBadge: AppIdentity.channel == .development)
            image?.accessibilityDescription = AppIdentity.displayName
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
        button.toolTip = "Tranquility Base. Click for the grid. "
            + "Tap ⌃ Ctrl + ⌥ Option to hear, hold ⌥ Option to reply"
    }
}
