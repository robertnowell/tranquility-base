import Foundation
import AppKit
import TranquilityCore

/// The individual self-test drills — one function per ruling, each proving
/// a specific fix or specific behavior holds, run by `selfTest()`
/// (`SelfTestDriver.swift`) under `--selftest-hud`. Split out of
/// `StatusHUD.swift` 23 Aug (App-lane P4) for the same reason as its
/// sibling files — see `SelfTestDriver.swift`'s own doc comment.
extension StatusHUD {

    /// The go-to-session drill (12 Aug, issue 14). The button's main-thread
    /// contract is immediacy: paint "Opening…", hand the walk to a background
    /// task, refuse re-entry — the beach ball was this action doing the walk
    /// in-line, 465 of 477 spindump samples deep in waitUntilExit while the
    /// event-tap watchdog took the hotkeys down with it. pid 1 never has a
    /// controlling terminal, so the background half must come home empty and
    /// drop the guard; that round trip reports three seconds later, on the
    /// mic drill's pattern. The label is NOT asserted at +3s — the ambient
    /// refresh may repaint it at any time, and the guard is the one piece of
    /// state this drill owns outright.
    func goToSessionDrill() {
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("Go to session drill."),
            sessionId: "goto-drill", pid: 1, project: "promotions copy", cwd: "/tmp")
        let t0 = Date()
        goToSession()
        let returned = Date().timeIntervalSince(t0)
        let painted = bodyLabel.stringValue
        let guardUp = goToSessionInFlight
        goToSession()   // a second tap mid-flight is a no-op, not a queue
        let secondTapHeld = bodyLabel.stringValue == painted && goToSessionInFlight
        SelfTest.report("goToSession", [
            ("returnsImmediately", returned < 0.1),
            ("paintsOpening", painted.hasPrefix("Opening")),
            ("guardRaised", guardUp),
            ("secondTapHeld", secondTapHeld),
        ])
        Permissions.log("selftest goToSession: returned in \(Int(returned * 1000))ms")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            SelfTest.report("goToSession.roundTrip", [
                ("guardDropped", !self.goToSessionInFlight),
            ])
            // The background half painted "no terminal for pid 1" over
            // whatever the cleanup left up; a deploy's selftest must not
            // strand that on the live panel.
            if self.bodyLabel.stringValue.contains("Couldn't find a terminal") {
                self.showIdle(rows: [])
            }
        }
    }

    /// The row menu is on the grid, and only where there is something to act on.
    ///
    /// The panel has no unit tests (rule 7), so this is the whole evidence that
    /// the menu follows liveness — and it is asserted as a PARTITION rather than
    /// as "the live one has a menu", because the failure that matters is a menu
    /// appearing on a row whose process is already gone. That row's verb is
    /// REVIVE, and a kill offered next to it would be a control that can only
    /// lie. The unlit-but-unprovable row is the third case and the reason this
    /// asks `StateLegend.isLive` rather than reading the lamp: liveness we could
    /// not establish is not liveness.
    ///
    /// The ORDER is asserted too (18 Aug). Go to agent is the harmless item and
    /// it holds the top; End session sits last, behind a separator, so the one
    /// item that kills a process is never where a fast pointer lands. A silent
    /// reorder would be invisible in every screenshot and expensive exactly
    /// once.
    func terminateDrill() {
        func row(_ id: String, _ lamp: Lamp,
                 revivable: Bool = false) -> SessionRow {
            SessionRow(id: id, name: "agent-\(id)", aux: id,
                                   lamp: lamp, revivable: revivable)
        }
        let rows = [
            // `busy` rather than `running` for the third live row: an IDLE
            // session is no longer drawn on the grid (18 Aug), and this drill
            // is about which LIVE rows carry the kill, not about membership.
            row("ready", .ready), row("working", .working), row("busy", .working),
            row("fault", .fault),
            row("exited", .unlit, revivable: true),   // REVIVE's row: no kill
            row("unproven", .unlit),                  // liveness unknown: no kill
        ]
        showIdle(rows: rows)
        let menus = Dictionary(uniqueKeysWithValues: gridRowsForTesting)
        let liveCarry = ["ready", "working", "busy", "fault"]
            .allSatisfy { menus[$0] == true }
        let deadDoNot = ["exited", "unproven"].allSatisfy { menus[$0] == false }
        let everyRowDrawn = rows.allSatisfy { menus[$0.id] != nil }
        let items = (waitingRows.arrangedSubviews.compactMap { $0 as? GridRowView }
            .first { $0.identifier?.rawValue == "ready" }?.menu?.items) ?? []
        // The menu names its target, because the name IS the confirmation.
        let titles = items.map(\.title)
        let named = titles.last ?? ""
        showIdle(rows: [])

        SelfTest.report("terminate", [
            ("everyRowDrawn", everyRowDrawn),
            ("liveRowsCarryIt", liveCarry),
            ("deadRowsDoNot", deadDoNot),
            ("goToAgentIsFirst", titles.first == "Go to agent"),
            ("destructiveIsLastAndSeparated",
             items.count == 3 && items[1].isSeparatorItem),
            ("theItemNamesItsTarget", named == "End session \u{201C}agent-ready\u{201D}"),
        ])
    }

    /// Quiet rows sink, and the active band keeps the order it arrived in.
    ///
    /// The ordering itself is a pure function on an array, so the interesting
    /// half is not "does idle go last" — it is that nothing ELSE moves. The
    /// bands feeding it are recency-ordered, and a partition that quietly
    /// reshuffled ties would spend that ordering without any visible symptom.
    /// So the drill checks positions, not just the tail.
    /// The panel breathes with live work, and with nothing else.
    ///
    /// Ruled 12 Aug: "it's your top eight or all the active sessions, whichever
    /// is larger", where active means green, blue or amber. The failure this
    /// guards is the panel growing for sessions that are merely alive, or for
    /// dead ones — which would make its height a measure of how long the
    /// machine has been on rather than of how much is happening.
    func elasticGridDrill() {
        func row(_ id: String, _ lamp: Lamp) -> SessionRow {
            SessionRow(id: id, name: id, aux: id, lamp: lamp)
        }
        // A generous screen, so the ceiling rather than the arithmetic decides.
        let big = NSScreen.main
        let quiet = (0..<30).map { row("q\($0)", .running) }
        let dead = (0..<30).map { row("d\($0)", .unlit) }
        let busy = (0..<14).map { row("a\($0)", .working) } + quiet
        let swamped = (0..<40).map { row("a\($0)", .ready) }

        SelfTest.report("elasticGrid", [
            ("quietDoesNotGrowIt",
             Self.gridRowsShown(quiet, screen: big) == Self.gridRowFloor),
            ("deadDoesNotGrowIt",
             Self.gridRowsShown(dead, screen: big) == Self.gridRowFloor),
            ("emptyStaysAtTheFloor",
             Self.gridRowsShown([], screen: big) == Self.gridRowFloor),
            ("activeGrowsIt", Self.gridRowsShown(busy, screen: big) == 14),
            ("neverBelowTheFloor",
             Self.gridRowsShown([row("a", .ready)], screen: big) == Self.gridRowFloor),
            // The regression that shipped 18 Aug: folding the switch into the
            // height collapsed the floor. The height must not know about
            // filed rows; the SLICE must.
            ("filedRowsDoNotShortenTheFloor",
             Self.gridRowsShown([row("f", .running)].map { $0.switchedOffCopy() },
                                screen: big) == Self.gridRowFloor),
            ("clampedByTheScreen",
             Self.gridRowsShown(swamped, screen: big) <= Self.gridRowCapacity(screen: big)),
            ("capacityIsSane",
             (Self.gridRowFloor...Self.gridRowCeiling)
                .contains(Self.gridRowCapacity(screen: big))),
            // The panel must never be taller than the screen it sits on, which
            // is the whole point of computing capacity rather than picking one.
            ("capacityFitsTheScreen", {
                guard let big else { return true }
                let rows = CGFloat(Self.gridRowCapacity(screen: big))
                    * (GridRowView.height + 1)
                return rows + 153 <= big.visibleFrame.height - 32
            }()),
        ])
    }

    /// How agents start is editable where settings live.
    ///
    /// The two failures worth guarding: rows that render but cannot be typed
    /// into (the panel is `.nonactivatingPanel`, so a field in a window that
    /// cannot become key has nowhere to put first responder — this cost a day
    /// on the list's filter), and a keyboard the pane forgets to give back.
    func launchSettingsDrill() {
        showSettings(voices: [], roster: [], note: "drill")
        let shown = launchRow?.isHidden == false && directoryRow?.isHidden == false
        let tookKeyboard = panel?.acceptsKey == true
        // What the fields SHOW is the stored value, not the resolved one — a
        // directory that has gone missing must be visible as itself.
        let showsStored = launchRow?.input.stringValue == AgentDefaults.load()
            && directoryRow?.input.stringValue == AgentDefaults.directoryAsTyped()
        // The tabs, which is what this pane was supposed to have all along.
        let tabsShown = settingsTabs?.isHidden == false
        showSettingsTab(.voices)
        let voicesPane = voiceList?.isHidden == false
            && launchRow?.isHidden == true && directoryRow?.isHidden == true
        let keyboardHandedBack = panel?.acceptsKey == false
        showSettingsTab(.agents)
        let backOnAgents = launchRow?.isHidden == false

        // THE REGRESSION, pinned: RECENT then VOICES used to draw the title
        // "Recent audio" over an empty roster with the voices hint beneath it,
        // because only RECENT asked the host for anything.
        showSettingsTab(.recent)
        let recentTitle = face.title
        showSettingsTab(.voices)
        let voicesAfterRecent = face.title == "Voices" && face.audioEvents == nil
        showSettingsTab(.agents)
        let agentsAfterVoices = face.title == "Agents" && face.voices.isEmpty

        SelfTest.report("settingsPanes", [
            ("recentIsItsOwnPane", recentTitle == "Recent audio"),
            ("voicesAfterRecentIsClean", voicesAfterRecent),
            ("agentsAfterVoicesIsClean", agentsAfterVoices),
            // The face carries one pane's payload, never two.
            ("noPaneInheritsAnother",
             !(face.audioEvents != nil && !face.voices.isEmpty)),
        ])

        SelfTest.report("settingsTabs", [
            ("tabBarIsShown", tabsShown),
            ("everyTabHasAPane", SettingsTab.allCases.count == 3),
            ("switchingLeavesTheOtherPaneBehind", voicesPane),
            // The keyboard belongs to one tab, not to the pane.
            ("leavingAgentsHandsTheKeyboardBack", keyboardHandedBack),
            ("comingBackRestoresIt", backOnAgents),
            ("stillInSettings", { if case .settings = state { return true }; return false }()),
        ])

        showIdle(rows: [])
        let released = panel?.acceptsKey == false
        let hiddenOnGrid = launchRow?.isHidden == true && directoryRow?.isHidden == true

        SelfTest.report("launchSettings", [
            ("rowsAppearInSettings", shown),
            ("takesTheKeyboard", tookKeyboard),
            ("fieldsShowWhatIsStored", showsStored),
            ("givesTheKeyboardBack", released),
            ("goneFromEveryOtherFace", hiddenOnGrid),
            // The whole point of one setting: every launch path reads it.
            ("oneSettingDrivesEveryLaunch",
             SessionLauncher.defaultCommand == AgentDefaults.load()
                && SessionLauncher.defaultDirectory == AgentDefaults.directory()),
        ])
    }

    /// The list face: the one surface that scrolls, and the only one that may.
    ///
    /// Two properties carry it. The verb has to match the row — offering
    /// REVIVE on a session that is still running is how the app crashed twice
    /// — and the filter has to be a plain predictable substring, because a
    /// filter you cannot predict is one you stop trusting.
    func pastAgentsDrill() {
        func item(_ id: String, _ name: String, live: Bool, cwd: String)
            -> PastAgentsList.Item {
            PastAgentsList.Item(
                row: SessionRow(
                    id: id, name: name, aux: SessionRow.shortId(id),
                    lamp: live ? .running : .unlit, revivable: !live),
                revivable: !live,
                haystack: [name, id, cwd].joined(separator: " ").lowercased())
        }
        // The last one is the row that broke: a stopped session puts its REASON
        // in the right column instead of an id, and a reason is a sentence.
        let stallReason = "silent for 24h, nothing written since it started this"
        let stalled = PastAgentsList.Item(
            row: SessionRow(
                id: "9f0c2b71-4444", name: "Blankshirts Mailchimp audit",
                aux: stallReason, lamp: .unlit, revivable: true,
                detail: stallReason),
            revivable: true,
            haystack: "blankshirts mailchimp audit")
        // And the row that broke NEXT: a title long enough to want the whole
        // width. Before the column was fixed it took it, and the time — the
        // one thing this face exists to say — rendered at zero points.
        let longTitled = PastAgentsList.Item(
            row: SessionRow(
                id: "6d1a77e0-5555",
                name: "Back to School 2026 Mailchimp email campaign for Blankshirts",
                aux: SessionRow.shortId("6d1a77e0-5555"), lamp: .unlit, revivable: true),
            revivable: true, haystack: "back to school",
            aux: "88m ago")
        let items = [
            item("a285f0a9-1111", "Plan Mirai campaign", live: false, cwd: "/tmp/kopi"),
            item("c53ce6f5-2222", "Review PR", live: true, cwd: "/tmp/kopi"),
            item("381c643c-3333", "Compare apartments", live: false, cwd: "/tmp/home"),
            stalled,
            longTitled,
        ]
        showPastAgents(items: items)
        let entered = state == .pastAgents
        let scrolls = pastList.subviews.contains { $0 is NSScrollView }
        // The right column says WHICH session or WHY it stopped, and nothing
        // else. The id half is the original claim — the row and the log name
        // the same session two different ways — and the reason half is the
        // 16 Aug exception, which this drill did not know about until a stalled
        // row was added to its sample and turned it red (19 Aug).
        let idsMatch = items.allSatisfy {
            $0.row.aux == SessionRow.shortId($0.row.id) || $0.row.aux == $0.row.detail
        }
        let tookKeyboard = panel?.acceptsKey == true
        // The name holds its column against a sentence in the right one.
        //
        // Asserted as a WIDTH, because the name was set correctly the whole
        // time — `displayName` had already resolved "Blankshirts Mailchimp
        // audit" — and Auto Layout then rendered it at zero points, so every
        // assertion about the string would have passed while the row on screen
        // named no agent at all (screenshot, 19 Aug). Half the row is the
        // claim: the reason is capped at `auxFraction` (0.38), so the name can
        // never be the thing that loses.
        panel?.contentView?.layoutSubtreeIfNeeded()
        let nameWidths = pastList.nameWidthsForTesting
        let stalledName = nameWidths.first { $0.id == "9f0c2b71-4444" }?.width ?? 0
        let listWidth = pastList.frame.width
        let stalledRowStillNamesItsAgent = stalledName > listWidth / 2
        // The mirror claim, and the one Robert reported: the time is a FIXED
        // column, so a title long enough to want the whole row cannot take it.
        // Asserted as a width for the same reason — "88m ago" was set on the
        // label the whole time and drawn at zero points.
        let auxWidths = pastList.auxWidthsForTesting
        let longTitleAux = auxWidths.first { $0.id == "6d1a77e0-5555" }?.width ?? 0
        let theTimeSurvivesALongTitle = longTitleAux >= PastRowView.auxColumn
        let everyRowKeepsItsColumn = auxWidths.allSatisfy { $0.width >= PastRowView.auxColumn }
        // And the title yields instead, rather than being drawn over the verb.
        let longTitleName = nameWidths.first { $0.id == "6d1a77e0-5555" }?.width ?? 0
        let theTitleTruncatesInstead =
            longTitleName > 0 && longTitleName <= listWidth - PastRowView.auxColumn
        // And nothing is lost: the tooltip carries the name AND the full
        // sentence, uncut, which is where the truncated half goes.
        let stalledTip = SessionRow.hoverText(for: stalled.row) ?? ""
        let theFullReasonIsReachable = stalledTip.contains(stallReason)
            && stalledTip.contains("Blankshirts Mailchimp audit")
        // Read WHILE the face is up. Everything below `goHomeFromPastAgents`
        // is a fact about the grid, which is what the first version of these
        // two accidentally asserted.
        let backInPlacardRow = pastBackButton?.isHidden == false
        let noSecondBack = backButton.isHidden
        let caretColour = pastList.caretColourForTesting
        // A sample bigger than any screen can draw, so the split is real.
        let sample = (0..<40).map {
            SessionRow(id: "s\($0)", name: "s\($0)", aux: "s\($0)",
                                   lamp: $0 < 3 ? .ready : ($0 < 30 ? .running : .unlit))
        }
        let drawn = Self.gridRows(sample)
        let rest = Array(Self.pastAgents(sample))
        let disjoint = Set(drawn.map(\.id)).isDisjoint(with: Set(rest.map(\.id)))
        let partitioned = drawn.count + rest.count
        // The verb follows liveness, never the other way round.
        let verbs = items.allSatisfy { $0.revivable == ($0.row.lamp == .unlit) }
        // The placard's text starts clear of the chevron sharing its row —
        // measured in window space, because the two live in different parents
        // and comparing raw minX across parents compares nothing (the original
        // overlap shipped precisely because nothing measured this).
        panel?.contentView?.layoutSubtreeIfNeeded()
        let indent = (stateLabel.attributedStringValue.length > 0
            ? stateLabel.attributedStringValue.attribute(
                .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            : nil)?.firstLineHeadIndent ?? 0
        let chevronMaxX = pastBackButton.convert(pastBackButton.bounds, to: nil).maxX
        let placardTextMinX = stateLabel.convert(stateLabel.bounds, to: nil).minX + indent
        let placardClearsChevron = placardTextMinX >= chevronMaxX - 1
        // Terminate rides the right-click, on exactly the rows that have a
        // process to end: live rows carry the menu, dead rows carry none.
        let menuByRow = Dictionary(uniqueKeysWithValues: pastList.rowsForTesting)
        let terminateFollowsLiveness = items.allSatisfy {
            menuByRow[$0.row.id] == !$0.revivable
        }
        goHomeFromPastAgents()

        SelfTest.report("pastAgents", [
            ("entersItsOwnState", entered),
            // The filter is a text field in a panel that is normally unable to
            // become key. Without this it renders, ignores the click, and looks
            // broken for a reason nothing on screen explains.
            ("takesTheKeyboardForFiltering", tookKeyboard),
            ("givesTheKeyboardBack", panel?.acceptsKey == false),
            // The caret is the one AppKit-coloured thing on this face, and the
            // colour it reaches for by default is the WORKING lamp's blue —
            // blinking, on a panel where blue means an agent has work in hand.
            ("caretIsNotTheWorkingLamp", caretColour != StateLegend.Palette.working),
            ("caretComesFromThePalette", caretColour == StateLegend.Palette.ink),
            ("itIsTheFaceThatScrolls", scrolls),
            // A stack view in a scroll view lays out from the BOTTOM unless it
            // is flipped, so the list opened on its oldest session — which
            // reads as a broken sort rather than as a coordinate system.
            ("opensAtTheTop", pastList.isAtTopForTesting),
            // The two surfaces partition one list: nothing is in both, nothing
            // is in neither. Asserted as a split rather than as two filters,
            // because a filter can be wrong in both directions at once.
            ("gridAndListAreDisjoint", disjoint),
            ("nothingIsLost", partitioned == sample.count),
            // Its header is one row, like the grid's.
            ("backSitsInThePlacardRow", backInPlacardRow),
            ("noSecondBackButton", noSecondBack),
            ("idMatchesTheLogs", idsMatch),
            ("stalledRowStillNamesItsAgent", stalledRowStillNamesItsAgent),
            ("theTimeSurvivesALongTitle", theTimeSurvivesALongTitle),
            ("everyRowKeepsItsColumn", everyRowKeepsItsColumn),
            ("theTitleTruncatesInstead", theTitleTruncatesInstead),
            ("theFullReasonIsReachable", theFullReasonIsReachable),
            ("verbFollowsLiveness", verbs),
            ("placardClearsChevron", placardClearsChevron),
            ("terminateFollowsLiveness", terminateFollowsLiveness),
            ("leavesCleanly", { if case .idle = state { return true }; return false }()),
        ])
    }

    /// The drop tray, on a real panel.
    ///
    /// Everything here is invisible to `swift test` by construction: whether
    /// a drag is refused, whether the chips on screen belong to the session
    /// the panel is addressing, and whether a drag resizes the window are
    /// facts about views. The tray's LOGIC is unit-tested in Core
    /// (AttachmentTrayTests); this asserts the half that draws.
    func dropTrayDrill() {
        let priorTarget = replyTargetForDrop
        let priorStaged = stagedFiles
        let priorUnstage = onUnstage
        defer {
            replyTargetForDrop = priorTarget
            stagedFiles = priorStaged
            onUnstage = priorUnstage
        }

        // A tray with two files for A, one for B — so a face addressing A can
        // be caught showing B's.
        var tray = ["A": ["/tmp/one.png", "/tmp/two.pdf"], "B": ["/tmp/other.png"]]
        var unstaged: (session: String, path: String)?
        stagedFiles = { tray[$0] ?? [] }
        onUnstage = { session, path in unstaged = (session, path) }

        // Addressing A, on a card.
        replyTargetForDrop = { (sessionId: "A", label: "promotions copy") }
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("A card with files attached."),
            sessionId: "A", pid: 1, project: "promotions copy", cwd: "/tmp")
        let chipsShowOnTheCard = !trayRow.isHidden
        let chipsAreTheStagedFiles =
            trayRow.displayedNamesForTesting == ["one.png", "two.pdf"]

        // The SEV 1, on the surface this time: the panel is addressing A, so
        // B's file must be nowhere on it. Core makes the wrong-session RIDE
        // impossible; this asserts the panel cannot even SHOW it, because the
        // chips are what licenses the attachment.
        let noOtherSessionsChips =
            !trayRow.displayedNamesForTesting.contains("other.png")

        // The invitation names its destination, and appears only while a drag
        // is actually over the panel.
        let overlayHiddenAtRest = dropOverlay.isHidden
        let heightBefore = panel?.frame.height ?? 0
        dropSurface?.onDragTargetChanged?("promotions copy")
        panel?.contentView?.layoutSubtreeIfNeeded()
        let overlayShows = !dropOverlay.isHidden
        let overlaySaysOneThing =
            dropOverlay.messageForTesting == "Drop file for agent here"
        // The sentence stays INSIDE the panel. Asserted as geometry rather
        // than as a length limit on the string: the first version printed the
        // destination's name and ran off the right edge, and a rule that says
        // "keep the text short" is a rule the next edit forgets. Measured
        // against a deliberately absurd string, so the constraint is what
        // holds the line and not the wording.
        dropOverlay.showForTesting(String(repeating: "wide ", count: 40))
        panel?.contentView?.layoutSubtreeIfNeeded()
        let sentenceFits = dropOverlay.textFitsForTesting
        dropSurface?.onDragTargetChanged?("promotions copy")
        panel?.contentView?.layoutSubtreeIfNeeded()
        // A drag must not resize the window under the pointer: the overlay is
        // parented outside the content stack precisely so the panel holds
        // still while you are aiming at it.
        let panelHeldStill = abs((panel?.frame.height ?? 0) - heightBefore) < 1
        dropSurface?.onDragTargetChanged?(nil)
        let overlayLeaves = dropOverlay.isHidden

        // No target, no invitation. A "drop here" the app cannot honour is
        // worse than a cursor that never invited you.
        replyTargetForDrop = { nil }
        let refusesWithNoTarget = dropSurface?.canAccept?() == nil
        render()
        let noChipsWithNoTarget = trayRow.isHidden

        // Back to A, then the chip's ✕: per path, and it names the session it
        // came from — a cross that cleared the other file would be the same
        // surprise the whole feature exists to avoid.
        replyTargetForDrop = { (sessionId: "A", label: "promotions copy") }
        render()
        trayRow.removeButtonsForTesting.first.map {
            _ = $0.target?.perform($0.action, with: $0)
        }
        let crossUnstagesOnePath = unstaged?.path == "/tmp/one.png"
        let crossNamesItsSession = unstaged?.session == "A"

        // The faces that address nobody: a list and a settings pane are not
        // conversations, and a chip there would name a session the face does
        // not show.
        tray["A"] = ["/tmp/one.png"]
        showPastAgents(items: [])
        let noChipsOnTheList = trayRow.isHidden
        goHomeFromPastAgents()
        render()

        SelfTest.report("dropTray", [
            ("chipsShowOnTheCard", chipsShowOnTheCard),
            ("chipsAreTheStagedFiles", chipsAreTheStagedFiles),
            ("noOtherSessionsChips", noOtherSessionsChips),
            ("overlayHiddenAtRest", overlayHiddenAtRest),
            ("overlayShowsOnDrag", overlayShows),
            ("overlaySaysOneThing", overlaySaysOneThing),
            ("sentenceStaysInsideThePanel", sentenceFits),
            ("panelHeldStillUnderTheDrag", panelHeldStill),
            ("overlayLeavesWithTheDrag", overlayLeaves),
            ("refusesWithNoTarget", refusesWithNoTarget),
            ("noChipsWithNoTarget", noChipsWithNoTarget),
            ("crossUnstagesOnePath", crossUnstagesOnePath),
            ("crossNamesItsSession", crossNamesItsSession),
            ("noChipsOnTheList", noChipsOnTheList),
        ])
    }

    func quietRowsDrill() {
        func row(_ id: String, _ lamp: Lamp) -> SessionRow {
            SessionRow(id: id, name: id, aux: id, lamp: lamp)
        }
        // Deliberately interleaved, and with two of each active lamp, so a
        // comparator that grouped by lamp rather than partitioning would fail.
        // The closed rows are seeded in the MIDDLE for the same reason: they
        // have to sink past the quiet band, not merely past the active one.
        let mixed = [row("w1", .working), row("i1", .running), row("d1", .unlit),
                     row("r1", .ready), row("i2", .running), row("d2", .unlit),
                     row("f1", .fault), row("w2", .working)]
        let sorted = SessionRow.quietRowsLast(mixed).map(\.id)

        SelfTest.report("quietRows", [
            ("closedLast", sorted.suffix(2) == ["d1", "d2"]),
            ("quietAboveClosed", Array(sorted[4...5]) == ["i1", "i2"]),
            ("activeKeepsArrivalOrder", Array(sorted.prefix(4)) == ["w1", "r1", "f1", "w2"]),
            ("nothingLost", sorted.count == mixed.count),
            ("allQuietIsStillAllQuiet",
             SessionRow.quietRowsLast([row("i1", .running), row("i2", .running)])
                .map(\.id) == ["i1", "i2"]),
        ])
    }

    /// The grid draws lit lamps, and nothing else.
    ///
    /// This drill was `liveRowsHoldTheirPlace` and asserted the opposite half
    /// of the same question — that a live session keeps its row however dim.
    /// Robert overruled that on 18 Aug, pointing at an idle socket drawn on the
    /// grid: "the grid is for lit fucking lamps." The earlier drill's real case
    /// survives and is kept below: the sessions it was written to protect were
    /// working or blocked, both LIT, and they still hold their rows.
    ///
    /// Reversed again 23 Aug, on a fresh screenshot: a dead test session sat
    /// in a floor slot ahead of a genuinely live, idle one that had been
    /// bumped to the list. `.running` (alive, quiet) now competes for floor
    /// slots ahead of `.unlit` (dead) — behind lit, same as always, and gone
    /// the moment something urgent needs the room. Idle is not back to being
    /// an entitlement; it is back to outranking dead for whatever the floor
    /// leaves over.
    func litLampsOnlyDrill() {
        func row(_ id: String, _ lamp: Lamp) -> SessionRow {
            SessionRow(id: id, name: id, aux: id, lamp: lamp)
        }
        let capacity = Self.gridRowCapacity()
        // The 18 Aug panel: nine lit, ten quiet. Nine lit rows alone already
        // fill this shape's slot budget, so this case looks the same under
        // both rulings — it needs `floorSlack` below to actually exercise
        // the 23 Aug reversal.
        let asItWas = SessionRow.quietRowsLast(
            (0..<9).map { row("lit\($0)", .ready) }
            + (0..<10).map { row("quiet\($0)", .running) })
        let drawn = Self.gridRows(asItWas)
        let listed = Array(Self.pastAgents(asItWas))

        // The case the superseded rule was written for, restated: a session
        // that is WORKING or BLOCKED is lit, and keeps its row.
        let busy = SessionRow.quietRowsLast(
            (0..<9).map { row("work\($0)", .working) }
            + [row("stuck", .fault)] + (0..<10).map { row("quiet\($0)", .running) })
        let busyDrawn = Self.gridRows(busy)

        // One lit session per slot, and one more than there is room for.
        let overflowing = (0..<(capacity + 1)).map { row("lit\($0)", .ready) }

        // Two lit rows, well under the floor of 8, leaves six floor slots
        // open — the exact shape that used to hand every one of them to a
        // dead session regardless of a live, idle one sitting right there.
        let floorSlack = SessionRow.quietRowsLast(
            (0..<2).map { row("lit\($0)", .ready) }
            + (0..<10).map { row("alive\($0)", .running) }
            + (0..<10).map { row("dead\($0)", .unlit) })
        let floorDrawn = Self.gridRows(floorSlack)

        // Everything the grid does not draw, whatever the reason.
        let everything = SessionRow.quietRowsLast(
            [row("lit", .ready), row("quiet", .running), row("dead", .unlit),
             SessionRow(id: "filed", name: "filed", aux: "filed",
                                    lamp: .running, switchedOff: true)])

        SelfTest.report("litLampsOnly", [
            ("everyLitRowIsDrawn", drawn.count == 9),
            ("noRoomLeftForIdleWhenLitFillsTheFloor", drawn.allSatisfy { $0.lamp.isLit }),
            ("quietGoesToTheListWhenThereIsNoRoom", listed.count == 10),
            // The superseded drill's real case, kept.
            ("workingAndBlockedKeepTheirRows",
             busyDrawn.count == 10 && busyDrawn.allSatisfy { $0.lamp.isLit }),
            // The one demotion that is not about the lamp: the edge of the glass.
            ("theScreenIsStillTheLimit", Self.gridRows(overflowing).count == capacity),
            ("overflowGoesToTheList",
             Self.pastAgents(overflowing).count == overflowing.count - capacity),
            // The 23 Aug reversal itself: with floor slack, alive fills it
            // ahead of dead, not the other way around.
            ("aliveFillsSpareFloorSlotsAheadOfDead",
             floorDrawn.filter { $0.lamp == .running }.count
                == min(10, Self.gridRowFloor - 2)
                && !floorDrawn.contains { $0.lamp == .unlit }),
            // Switched-off still leaves entirely — the switch's whole job is
            // to make a session idle by hand, and a row that keeps competing
            // for a floor slot despite being switched off would make the
            // switch look broken. `dead` and `quiet` both now draw when the
            // floor has room; `filed` (switched off) never does.
            ("switchedOffStillLeavesEntirely",
             Set(Self.pastAgents(everything).map(\.id)) == ["filed"]
                && !Self.gridRows(everything).contains { $0.id == "filed" }),
            ("nothingIsLost",
             Self.gridRows(everything).count + Self.pastAgents(everything).count
                == everything.count),
            // The panel's HEIGHT keeps its floor — that number is geometry and
            // was never the membership rule. Folding the two together shipped a
            // regression on 18 Aug; see `gridRows`.
            ("theFloorIsStillGeometry",
             Self.gridRowsShown([row("q", .running)]) == Self.gridRowFloor),
        ])
    }

    /// A restarted agent is on the grid, not in Past Agents.
    ///
    /// Ruled 19 Aug, on `04d50469`: killed between a tool call and its result,
    /// resumed seven minutes later, and filed away by the panel while its owner
    /// sat looking at it. Robert: *"when you restart an agent, the lamp should
    /// immediately be on … it should be on the grid, not in past agents."*
    /// Re-ruled the same evening, wider: *"anytime I click on an agent to
    /// resurrect it, it is no longer idle."* So resumption is the membership
    /// fact and it does not care what the old turn was doing — including a
    /// conversation that had finished cleanly, which the first cut left quiet.
    ///
    /// Drilled as the whole path rather than as the rule alone, because the
    /// rule was never the doubtful part: `AgentRestart` is unit-tested and was
    /// green while the row was still in the wrong place. What this asserts is
    /// that the verdict reaches the LAMP and the lamp reaches the GRID — the
    /// two joins that the 18 Aug downgrade sat between.
    func restartedAgentDrill() {
        func row(_ id: String, _ lamp: Lamp) -> SessionRow {
            SessionRow(id: id, name: id, aux: id, lamp: lamp)
        }
        // The real clocks off this machine at 22:32: the conversation's last
        // word at 22:25:22, the process up at 22:32:22.
        let lastWord = Date(timeIntervalSince1970: 1_787_178_322)
        let restart = Date(timeIntervalSince1970: 1_787_178_742.354)
        // The lamp half of `lampAndReason`, for a process reporting `idle` —
        // which is where every one of these rows used to land as quiet.
        func lamp(_ activity: SessionActivity, startedAt: Date?)
            -> (lamp: Lamp, aux: String) {
            guard AgentRestart.resumed(startedAt: startedAt, lastWord: lastWord),
                  let said = AgentRestart.reason(for: activity)
            else { return (.running, "quiet") }
            return (.fault, said.short)
        }
        let interrupted = lamp(.working, startedAt: restart)
        let reopened = lamp(.idle, startedAt: restart)
        let stalled = lamp(.stalled(reason: "silent for 2h"), startedAt: restart)
        // The same file, read against a process that has been up all along.
        let untouched = lamp(.working, startedAt: lastWord.addingTimeInterval(-600))
        let rows = SessionRow.quietRowsLast([
            row("interrupted", interrupted.lamp), row("reopened", reopened.lamp),
            row("neverRestarted", untouched.lamp)])
        let drawn = Set(Self.gridRows(rows).map(\.id))
        let listed = Set(Self.pastAgents(rows).map(\.id))

        SelfTest.report("restartedAgent", [
            ("aRestartLightsTheLamp", interrupted.lamp == .fault),
            ("aRestartedStallLightsToo", stalled.lamp == .fault),
            // The 19 Aug widening: a clean finish is still a restart.
            ("aReopenedConversationLightsToo", reopened.lamp == .fault),
            ("theRowSaysWhichKindItIs", interrupted.aux != reopened.aux),
            ("bothAreDrawnOnTheGrid",
             drawn.isSuperset(of: ["interrupted", "reopened"])),
            ("neitherIsFiledAway",
             listed.isDisjoint(with: ["interrupted", "reopened"])),
            // The narrowness that survives: this must not light every live row.
            // Placement moved to `drawn` (23 Aug, gridRows now fills spare
            // floor slots with `.running` rows ahead of dead ones) — three
            // rows here is well under the floor, so an untouched idle row
            // now draws on the grid same as its restarted neighbours; the
            // real assertion is the LAMP, which is untouched either way.
            ("anUnrestartedSessionIsUntouched",
             untouched.lamp == .running && drawn.contains("neverRestarted")),
            // And it retires itself the moment the session is spoken to.
            ("typingEndsIt",
             !AgentRestart.resumed(startedAt: restart,
                                   lastWord: restart.addingTimeInterval(30))),
        ])
    }

    /// A session that is not awake is still a row, and tapping it is a
    /// different verb — or, when nothing was proven, no verb at all.
    ///
    /// Ruled 11 Aug: "They are equally valid agents whether or not they are
    /// awake." The dangerous half is the third case. `claude --resume` against
    /// a session that is actually still running leaves the original process
    /// alive and adds a second live entry under the same id, which crashed the
    /// app twice (06 Aug 14:35, 07 Aug 17:39). An unlit row whose liveness
    /// could not be proven must therefore do NOTHING on tap rather than fall
    /// through to the announce path it used to share.
    func closedRowsDrill() {
        func row(_ id: String, _ lamp: Lamp,
                 revivable: Bool = false) -> SessionRow {
            SessionRow(id: id, name: id, aux: id,
                                   lamp: lamp, revivable: revivable)
        }
        let unlit = Lamp.unlit

        // The row is drawn by presence, not by a fifth colour: nothing in the
        // socket, a fainter ring than the seated lamp, and stepped-back ink.
        let noFill = unlit.fill.alphaComponent == 0
        let fainterRing = (unlit.ring?.alphaComponent ?? 1)
            < (Lamp.running.ring?.alphaComponent ?? 0)

        // Every drill row goes through showIdle so the grid actually builds
        // one — a row that sorts correctly and then fails to render is the
        // failure this layer exists to catch.
        showIdle(rows: [row("live", .ready), row("dead", unlit, revivable: true),
                        row("unproven", unlit)])
        let built = waitingRows.arrangedSubviews.compactMap { $0 as? GridRowView }

        SelfTest.report("closedRows", [
            ("unlitHasNoFill", noFill),
            ("unlitRingIsFainterThanQuiet", fainterRing),
            ("unlitDimsTheRow", unlit.rowAlpha < 1 && Lamp.running.rowAlpha == 1),
            ("liveRowAnnounces", SessionRow.action(for: row("live", .ready)) == .announce),
            // Amber does not speak, it points (18 Aug). A blocked session is
            // not in the waiting set, so the announcement it used to trigger
            // had nothing to say and left the panel sitting on Preparing.
            ("amberRowGoesToAgent",
             SessionRow.action(for: row("amber", .fault)) == .goToAgent),
            // ...and is still a live row, so it keeps its menu. The two
            // questions are asked through one function precisely so this
            // cannot come apart.
            ("amberRowIsStillLive", SessionRow.isLive(row("amber", .fault))),
            // Blue joined amber on 24 Aug, same reason and not a second
            // one: work in hand is not an unread turn, so the tap is the
            // door rather than the voice.
            ("workingRowGoesToAgent",
             SessionRow.action(for: row("working", .working)) == .goToAgent),
            ("workingRowIsStillLive", SessionRow.isLive(row("working", .working))),
            // ...and the dark lamp closed the rule the same day. Announce
            // on a quiet row read nothing and returned to the grid, so the
            // tap was a silent no-op — amber's 18 Aug complaint, surviving
            // where it was hardest to see.
            ("quietRowGoesToAgent",
             SessionRow.action(for: row("quiet", .running)) == .goToAgent),
            ("quietRowIsStillLive", SessionRow.isLive(row("quiet", .running))),
            // Green is the only lamp left that speaks.
            ("greenIsTheOnlyLampThatAnnounces",
             SessionRow.action(for: row("live", .ready)) == .announce
             && SessionRow.action(for: row("quiet", .running)) != .announce),
            ("revivableRowRevives",
             SessionRow.action(for: row("dead", unlit, revivable: true)) == .revive),
            ("unprovenRowDoesNothing",
             SessionRow.action(for: row("unproven", unlit)) == SessionRow.RowAction.none),
            ("closedRowsStillRender", built.count == 3),
        ])
        showIdle(rows: [])
    }

    /// The lamp is the grid's membership control, and its verb depends on the
    /// face it was clicked on.
    ///
    /// A drill rather than a unit test for the half that cannot be reached
    /// otherwise. The mapping is a pure function and could be tested anywhere,
    /// but "a filed row is never drawn on the grid" is a fact about a slice of
    /// an array a view builder produces, and it is the half that carries the
    /// user's click: if a filed row reaches the grid, its lamp offers `turnOff`
    /// on a session that is already off and the switch has no way back.
    func lampSwitchDrill() {
        func row(_ id: String, _ lamp: Lamp,
                 revivable: Bool = false, off: Bool = false) -> SessionRow {
            SessionRow(id: id, name: id, aux: id, lamp: lamp,
                                   revivable: revivable, switchedOff: off)
        }
        let unlit = Lamp.unlit

        // One session in each state, one of them filed, through the real
        // banding and the real partition.
        let rows = SessionRow.quietRowsLast([
            row("asking", .ready), row("busy", .working), row("stuck", .fault),
            row("quiet", .running), row("filed", .running, off: true),
            row("dead", unlit, revivable: true),
        ])
        let drawn = Self.gridRows(rows)
        let listed = Array(Self.pastAgents(rows))
        let filedIsNeverOnTheGrid = !drawn.contains { $0.switchedOff }
        let filedIsInTheList = listed.contains { $0.id == "filed" }
        let nothingIsLost = drawn.count + listed.count == rows.count

        // And the list actually hands every row a lamp target — including the
        // live ones, which is the case that used to navigate to a Terminal tab.
        let items = rows.map {
            PastAgentsList.Item(row: $0, revivable: $0.revivable, haystack: $0.name)
        }
        showPastAgents(items: items)
        let everyRowHasASwitch = pastList.lampTargetsForTesting.count == items.count
        goHomeFromPastAgents()

        SelfTest.report("lampSwitch", [
            // The sentence: on the grid it files away, in the list it brings back.
            ("gridFilesEveryLitRow",
             [row("a", .ready), row("b", .working), row("c", .fault), row("d", .running)]
                .allSatisfy { SessionRow.lampAction(for: $0, on: .grid) == .turnOff }),
            ("listRestoresEveryLiveRow",
             [row("a", .ready), row("b", .working), row("c", .fault), row("d", .running)]
                .allSatisfy { SessionRow.lampAction(for: $0, on: .list) == .turnOn }),
            // The one exception, and it is the same on both faces: you cannot
            // flip a terminated process on, you have to resurrect it.
            ("deadRevivesOnEitherFace",
             SessionRow.lampAction(for: row("x", unlit, revivable: true), on: .grid) == .revive
                && SessionRow.lampAction(for: row("x", unlit), on: .list) == .revive),
            // Off is not a kill: nothing in the lamp's vocabulary terminates.
            ("noLampVerbEndsAProcess",
             Set([SessionRow.LampAction.turnOff, .turnOn, .revive]).count == 3),
            // Membership, through the real partition rather than by assertion.
            ("filedIsNeverOnTheGrid", filedIsNeverOnTheGrid),
            ("filedIsInTheList", filedIsInTheList),
            ("nothingIsLost", nothingIsLost),
            // Only the SWITCH files a row away now (23 Aug: `.running` draws
            // on the grid same as anything else when the floor has spare
            // room, six rows here is well under it) — `switchedOff` is its
            // own exclusion, not something `.running` shares by default.
            ("onlySwitchedOffLeavesTheGrid",
             drawn.contains { $0.id == "quiet" } && !drawn.contains { $0.id == "filed" }),
            ("pastAgentsRowsCarryTheSwitch", everyRowHasASwitch),
            ("switchIsTheSameSizeOnBothFaces",
             GridRowView.lampHitWidth == GridRowView.lampColumn),
        ])
    }

    /// Picking a session up: what a left-click on a LIVE row in Past Agents
    /// does, and what it no longer does.
    ///
    /// Ruled 19 Aug, after a click sent him to a Terminal window he had not
    /// asked for: *"when I click on an idle agent … it should turn the lamp on,
    /// open the agent card. Because it's alive, clicking on it obviously means
    /// I want it to be alive. Now it's in the grid."* GO TO AGENT keeps its
    /// place on the right-click, next to END SESSION.
    ///
    /// The wiring is the whole risk here, so the drill calls the row's real tap
    /// closure and watches which of the panel's doors open. The handlers are
    /// swapped for recorders and put back — announcing for real inside a drill
    /// would speak out loud on every launch.
    func pickUpDrill() {
        let live = SessionRow(id: "alive", name: "alive", aux: "alive",
                                          lamp: .running)
        let dead = SessionRow(id: "gone", name: "gone", aux: "gone",
                                          lamp: .unlit, revivable: true)
        showPastAgents(items: [
            PastAgentsList.Item(row: live, revivable: false, haystack: live.name),
            PastAgentsList.Item(row: dead, revivable: true, haystack: dead.name),
        ])
        // The row says which verb it has.
        let verbs = pastList.verbsForTesting
        let liveSaysOpen = verbs["alive"] == "OPEN \u{203A}"
        let deadStillRevives = verbs["gone"] == "REVIVE \u{203A}"
        // Go to agent lives on the right-click now, on the live row only.
        let menus = pastList.menuTitlesForTesting
        let goToIsInTheMenu = menus["alive"]?.contains { $0.hasPrefix("Go to ") } == true
        let terminateIsStillThere = menus["alive"]?.contains { $0.hasPrefix("Terminate ") } == true
        let deadHasNoMenu = menus["gone"] == nil

        // The tap itself, through the real closure.
        let realRestore = onRestoreLamp, realPick = onPickWaiting
        let realGoTo = onGoToSession, realHome = onBreadcrumbHome
        var switchedOn: String?, cardOpened: String?, wentToTerminal: String?
        onRestoreLamp = { switchedOn = $0 }
        onPickWaiting = { cardOpened = $0 }
        onGoToSession = { wentToTerminal = $0 }
        onBreadcrumbHome = {}
        pastList.onPick?("alive", false)
        let tapStayedOnThePanel = wentToTerminal == nil
        // …and the menu's verb, which must still reach the terminal.
        pastList.onGoTo?("alive")
        let menuWentToTerminal = wentToTerminal == "alive"
        onRestoreLamp = realRestore; onPickWaiting = realPick
        onGoToSession = realGoTo; onBreadcrumbHome = realHome
        goHomeFromPastAgents()

        SelfTest.report("pickUp", [
            ("theTapTurnsTheLampOn", switchedOn == "alive"),
            ("theTapOpensTheCard", cardOpened == "alive"),
            // The regression this exists to prevent, stated as its own line.
            ("theTapDoesNotJumpToTheTerminal", tapStayedOnThePanel),
            ("theMenuStillDoes", menuWentToTerminal),
            ("goToAgentIsOnTheRightClick", goToIsInTheMenu),
            ("endSessionKeptItsPlace", terminateIsStillThere),
            ("aDeadRowHasNeitherVerb", deadHasNoMenu),
            ("theRowNamesItsVerb", liveSaysOpen && deadStillRevives),
            // And what the switch it flips is worth: an idle session the user
            // picked up is lit, so the grid draws it.
            ("aPickedUpSessionIsDrawnOnTheGrid",
             Self.gridRows([SessionRow(id: "alive", name: "alive",
                                                   aux: "standing by", lamp: .fault)])
                .contains { $0.id == "alive" }),
        ])
    }

    /// The state that is permanently on this machine and had no name until
    /// 19 Aug: a session locked at the resume prompt.
    ///
    /// Robert: *"it happens every single time, and it's locked. But not
    /// detectable. You can see it's treated as green, like a ready state."* The
    /// row had a stored waiting turn, so the waiting band drew it green from the
    /// store without ever asking the process — which was saying `status: waiting
    /// · waitingFor: dialog open` the whole time.
    ///
    /// Drilled at the join rather than at the rule (`WaitingAtTests` has the
    /// rule): the words have to reach the row, the row has to reach the grid,
    /// the tap has to reach the terminal — and the SEND path has to refuse the
    /// same session the lamp is describing. A panel that shows "answer this in
    /// the terminal" while quietly typing into the dialog would be worse than
    /// the green row it replaced.
    func resumePromptDrill() {
        let at = WaitingAt.resumePrompt
        let locked = SessionRow(
            id: "locked", name: "PRs in the Hub", aux: at.short,
            lamp: .fault, detail: at.full)
        showIdle(rows: [locked])
        panel?.contentView?.layoutSubtreeIfNeeded()
        let drawn = Self.gridRows([locked]).contains { $0.id == "locked" }
        let tip = waitingRows.arrangedSubviews
            .compactMap { $0 as? GridRowView }
            .first { $0.identifier?.rawValue == "locked" }?.toolTip

        SelfTest.report("resumePrompt", [
            // Not green. That is the whole complaint.
            ("aLockedSessionIsNotReady", locked.lamp != .ready),
            ("itIsDrawnOnTheGrid", drawn),
            // Amber's tap is the one move that helps: it puts you in the tab
            // where the dialog is.
            ("theTapGoesToTheTerminal",
             SessionRow.action(for: locked) == .goToAgent),
            ("theRowNamesTheDialog", locked.aux == "waiting at the resume prompt"),
            // The hover is "name, newline, reason" (see StateLegend.hoverText),
            // so the assertion is that the sentence is IN it. The first version
            // of this line compared the tooltip to the reason alone and failed
            // on a build where nothing was wrong but the drill.
            ("theWholeSentenceIsReachable", tip?.contains(at.full) == true),
            // The pair that must never disagree: the lamp says answer it there,
            // and the send path refuses to type into it.
            ("thePanelWillNotTypeIntoIt",
             !Readiness.waiting(Readiness.dialogOpen).canDispatch
                && !at.acceptsTypedReply),
            // And the daily loop is untouched — a question still takes a reply.
            ("aQuestionStillTakesAReply",
             Readiness.waiting("input needed").canDispatch
                && WaitingAt.question.acceptsTypedReply),
        ])
    }

    /// The weight IS the read state (ruled 13 Aug): an unread ready row is
    /// semibold, an opened one drops to medium, the lamp identical in both —
    /// read is not answered. A drill because the mapping lives in a view
    /// initializer no unit test can reach, and a weight that quietly stopped
    /// varying would put the grid back to two states it cannot tell apart.
    func readIntensityDrill() {
        let items = [
            SessionRow(id: "unread", name: "unread", aux: "u",
                                   lamp: .ready, read: .unread),
            SessionRow(id: "opened", name: "opened", aux: "o",
                                   lamp: .ready, read: .opened),
            SessionRow(id: "w-unread", name: "working unread", aux: "wu",
                                   lamp: .working, read: .unread),
            SessionRow(id: "w-opened", name: "working opened", aux: "wo",
                                   lamp: .working, read: .opened),
            SessionRow(id: "idle", name: "idle, nothing waiting", aux: "i",
                                   lamp: .running, read: .none),
        ]
        // Built directly rather than through `showIdle`, because this drill's
        // subject was never membership — it is the mapping from read state to
        // ink and lamp, which lives in a view initializer no unit test can
        // reach. Where each row LANDS is asserted at the bottom, through the
        // real partition.
        let built = items.map {
            GridRowView(item: $0, auxWidth: 40, target: self,
                        action: #selector(sessionRowTapped(_:)))
        }
        let label = { (id: String) in
            built.first { $0.identifier?.rawValue == id }?.nameLabel
        }
        let lampFill = { (id: String) -> CGColor? in
            built.first { $0.identifier?.rawValue == id }?.lampLayer?.backgroundColor
        }
        // Hollow == no fill. Read off the layer the row actually built, not
        // recomputed from the item, or the drill would be asserting its own
        // arithmetic rather than the panel's.
        func hollow(_ id: String) -> Bool { (lampFill(id)?.alpha ?? 1) == 0 }
        func solid(_ id: String) -> Bool { (lampFill(id)?.alpha ?? 0) > 0 }
        // The ink channel is asserted by LUMINANCE, not by identity with a
        // palette constant: the claim this drill has to defend is "you can
        // see which rows you have opened", and only a measured gap says that.
        // The weight-only version passed its own assertion and failed the
        // user on sight (13 Aug), so the assertion moved to the quantity the
        // eye actually uses.
        let unreadL = label("unread")?.textColor.map(StateLegend.Measure.relativeLuminance) ?? 0
        let openedL = label("opened")?.textColor.map(StateLegend.Measure.relativeLuminance) ?? 0
        let workingUnreadL = label("w-unread")?.textColor
            .map(StateLegend.Measure.relativeLuminance) ?? 0
        let workingOpenedL = label("w-opened")?.textColor
            .map(StateLegend.Measure.relativeLuminance) ?? 0
        let idleL = label("idle")?.textColor
            .map(StateLegend.Measure.relativeLuminance) ?? 0
        SelfTest.report("readIntensity", [
            // The AmberConsole law, asserted so it cannot rot back: NO row
            // is bold. The panel broke this quietly for the grid's whole
            // life and nobody noticed until it was asked to carry meaning.
            ("nothingIsBold", built.allSatisfy {
                $0.nameLabel.font == ChromeType.mono(ofSize: 13, weight: .medium) }),
            ("unreadIsBrightest", unreadL > openedL && unreadL > idleL),
            // Idle and opened rest at ONE level — "the idle sessions should
            // not be brighter than read active sessions" (16 Aug). Equality
            // is the claim, so equality is what is measured.
            ("idleRestsWithOpened", abs(idleL - openedL) < 0.0001),
            ("dimmingIsVisible", unreadL > 0 && (unreadL - openedL) / unreadL > 0.15),
            ("openedIsNotDead", unreadL > 0 && (unreadL - openedL) / unreadL < 0.40),
            ("unreadLampIsSolid", solid("unread") && solid("w-unread")),
            ("openedLampIsHollow", hollow("opened")),
            // Advisory blue carries NO read state: never hollow, never at
            // attention ink, whichever side of read it is on. The legend
            // calls it "news, nothing for you to do"; the panel has to agree.
            ("advisoryIsNeverHollow", solid("w-unread") && solid("w-opened")),
            ("advisoryAlwaysRests",
             abs(workingUnreadL - openedL) < 0.0001 && abs(workingOpenedL - openedL) < 0.0001),
            // An idle row keeps its own lamp: hollowing it would claim it had
            // been read, which is a thing that never happened to it.
            ("idleLampIsUntouched", solid("idle")),
            ("allRendered", built.count == 5),
            // ...and they still reach a face between them: five rows is well
            // under the floor of 8, so as of 23 Aug the idle row draws
            // alongside the four lit ones — the grid fills spare floor slots
            // with `.running` before anything is filed to the list at all.
            ("theIdleRowDrawsWithSpareFloorRoom",
             Self.gridRows(items).contains { $0.id == "idle" }
                && Self.pastAgents(items).isEmpty),
            ("everyRowLandsOnTheGridWithSpareRoom", Self.gridRows(items).count == 5),
        ])
        showIdle(rows: [])
    }

    /// The identity opens the tab — but only when there is a tab.
    ///
    /// The door is derived from `currentTarget`, not stored per face, which is
    /// correct only for as long as `currentTarget` is nil on every face whose
    /// title is not a session. That is true today (idle and showVoices both
    /// clear it) and it is the kind of thing that stops being true quietly. So
    /// it is asserted rather than trusted: a title that offers to open a tab
    /// that is not there would fail at the click, which is the worst place to
    /// find out.
    ///
    /// Also asserts the topic line stays dead. It was removed because it said
    /// the body's own sentence with the detail taken out, and it is exactly the
    /// sort of thing a later pass restores meaning well.
    func titleDoorDrill() {
        var checks: [(String, Bool)] = []

        currentTarget = ("drill", 1, "promotions copy")
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("Finished the poller. Go?"),
            sessionId: "drill", pid: 1, project: "promotions copy", cwd: "/tmp")
        checks.append(("sessionTitleIsADoor", titleLabel.isADoor))
        checks.append(("titleIsOneLine", titleLabel.maximumNumberOfLines == 1))
        // The identity, alone. A second line here is the topic coming back.
        checks.append(("noSecondLine", !titleLabel.stringValue.contains("\n")))

        showSettings(voices: [], roster: [], note: "")
        checks.append(("settingsTitleIsNotADoor", !titleLabel.isADoor))

        showIdle(rows: [])
        checks.append(("idleClearsTheTarget", currentTarget == nil))

        SelfTest.report("titleDoor", checks)
    }

    /// A card's prose is selectable, and selects itself never.
    ///
    /// The 16 Aug screenshot: a card came back from a turn with its whole body
    /// highlighted, in a light-grey band that put `ink` at 1.23:1 — text and
    /// selection both, unreadable, and untouched by any hand. Two independent
    /// faults, so two independent halves here.
    ///
    /// The panel cannot be photographed by a drill, so the second half is
    /// asserted where it is caused: the panel's declared appearance. `.aqua` on
    /// a dark console is what dressed the selection band for a light ground.
    func selectionDrill() {
        var checks: [(String, Bool)] = []
        currentTarget = ("drill", 1, "promotions")
        _ = showAnnouncement(
            spoken: SpokenTextSanitizer().sanitize("The poller is fixed. Go?"),
            sessionId: "drill", pid: 1, project: "promotions", cwd: "/tmp")

        // Nothing selects itself. Both halves: no field editor is installed, and
        // asking for one the way the window does on becoming key is refused.
        checks.append(("aCardArrivesUnselected", bodyLabel.currentEditor() == nil))
        checks.append(("noSelection", !bodyLabel.hasSelection))
        if let panel {
            _ = panel.makeFirstResponder(bodyLabel)
            checks.append(("theWindowCannotHandItTheKeyboard",
                           bodyLabel.currentEditor() == nil))

            let inside = bodyLabel.convert(
                NSPoint(x: bodyLabel.bounds.midX, y: bodyLabel.bounds.midY), to: nil)
            func press(at point: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)
            }
            let tab = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\t",
                charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
            // The gate, in all four directions. The third and fourth are the
            // ones that were failing: the window picks a first responder on
            // becoming key with no mouse event at all, and Tab walks the key
            // view loop into any selectable field.
            checks.append(("aPressOnTheWordsSelects", bodyLabel.acceptsPress(press(at: inside))))
            checks.append(("aPressElsewhereDoesNot",
                           !bodyLabel.acceptsPress(press(at: NSPoint(x: -80, y: -80)))))
            checks.append(("noEventDoesNot", !bodyLabel.acceptsPress(nil)))
            checks.append(("theKeyboardDoesNot", !bodyLabel.acceptsPress(tab)))
        }

        // A hand-made selection survives a repaint that changed only the ink —
        // the karaoke cursor rewrites this label once per spoken word — and is
        // dropped the moment the WORDS change, because it is then a selection
        // of text that is no longer there.
        bodyLabel.selectText(nil)
        let madeByHand = bodyLabel.hasSelection
        paintInkForTesting(displayCursor: 4)
        checks.append(("aRepaintKeepsIt", madeByHand && bodyLabel.hasSelection))
        bodyLabel.stringValue = "A different turn, with different words in it."
        checks.append(("newWordsDropIt", !bodyLabel.hasSelection))
        checks.append(("andGiveTheKeyboardBack", bodyLabel.currentEditor() == nil))

        // The cause of the unreadable band. `.aqua` was pinned when the console
        // was light putty and did not follow it into the dark (09 Aug).
        checks.append(("panelIsDressedForItsOwnSurface",
                       panel?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))

        SelfTest.report("selection", checks)
        showIdle(rows: [])
    }

    /// Every control answers the pointer, and answers it the same way.
    ///
    /// The standard is docs/rulings/ruling-the-panel-answers-the-pointer.md, written
    /// after the panel was measured against its own inventory: two cursor rects
    /// in the
    /// whole app, and sixteen buttons that looked exactly like the prose beside
    /// them until you clicked one.
    ///
    /// The drill asserts the STANDARD, not the call sites: that every control
    /// is a `ConsoleButton` (which is where the cursor rect lives, so being one
    /// IS rule 1), that its hover ink is a real step away from its resting ink
    /// and clears the text floor, and that nothing rests at `ink` — rule 4,
    /// which is the rule a new button is most likely to break, because `ink` is
    /// the obvious colour to reach for and it is the one colour with no answer
    /// to the pointer.
    func hoverDrill() {
        var checks: [(String, Bool)] = []
        let controls: [(String, ConsoleButton?)] = [
            ("go", goButton), ("openPage", openPageButton), ("gear", gearButton),
            ("collapse", collapseButton), ("back", backButton),
            ("pastBack", pastBackButton), ("dontSend", dontSendButton),
            ("micSettings", micSettingsButton), ("newSession", newSessionButton),
            ("cancelTranscription", cancelTranscriptionButton),
            ("retryTranscription", retryTranscriptionButton),
        ]
        for (name, control) in controls {
            guard let control, let resting = control.restingInk else {
                checks.append(("\(name)Exists", control != nil))
                continue
            }
            guard let hover = control.hoverInkForTesting else { continue }
            // Rule 4 first: at `ink` the ramp has no step, and `hovered`
            // answers with the resting colour to say so.
            checks.append(("\(name)RestsBelowInk", resting != StateLegend.Palette.ink))
            checks.append(("\(name)StepsOnHover", hover != resting))
            // Not a fixed floor — a hover owes what its rest owes (see
            // `contrastFloors`). What it must never do is make a control
            // HARDER to read at the moment somebody is pointing at it, and
            // that is the invariant worth pinning.
            checks.append(("\(name)HoverIsMoreLegibleThanRest",
                           StateLegend.Measure.contrast(hover, StateLegend.Palette.surface)
                           > StateLegend.Measure.contrast(resting, StateLegend.Palette.surface)))
            control.setHoveringForTesting(true)
            let lit = control.currentInkForTesting
            control.setHoveringForTesting(false)
            let unlit = control.currentInkForTesting
            checks.append(("\(name)WearsIt", lit == hover && unlit == resting))
        }

        // The step function itself, over every ink anything actually rests at
        // — including the three the old ramp could not answer (the pill's
        // amber, the go-green, and `ink`, which is the card's title).
        //
        // Two properties, and the second is the one a fraction-based step
        // silently loses: every lift is the SAME perceptual distance, and it is
        // far enough to see. The lamps' own floor is ΔL* 6.0, from 4.2
        // measuring invisible at 9px; text is bigger, so the step is 8 and the
        // drill accepts a point of slack either side of it.
        for (name, resting) in [
            ("faint", StateLegend.Palette.faint), ("hint", StateLegend.Palette.hint),
            ("muted", StateLegend.Palette.muted), ("secondary", StateLegend.Palette.secondary),
            ("ink", StateLegend.Palette.ink), ("accent", StateLegend.Palette.accent),
            ("fault", StateLegend.Palette.fault), ("ready", StateLegend.Palette.ready),
        ] {
            let step = StateLegend.Measure.lightnessGap(
                resting, StateLegend.hovered(resting))
            checks.append(("\(name)LiftsOneStep",
                           abs(step - StateLegend.hoverStep) <= 1))
        }
        // Saturation survives the lift, which is what keeps a caution a caution
        // and a go-lamp green. Blending toward `ink` was what broke this.
        func saturation(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            let high = max(c.redComponent, c.greenComponent, c.blueComponent)
            let low = min(c.redComponent, c.greenComponent, c.blueComponent)
            return high == 0 ? 0 : (high - low) / high
        }
        for (name, resting) in [("fault", StateLegend.Palette.fault),
                                ("ready", StateLegend.Palette.ready)] {
            checks.append(("\(name)KeepsItsHue",
                           abs(saturation(resting)
                               - saturation(StateLegend.hovered(resting))) < 0.02))
        }

        SelfTest.report("hover", checks)
    }

    /// Assert the palette still measures what the ruling says it measures.
    ///
    /// This drill renders nothing. It exists because every other drill here
    /// checks that the panel LAID OUT correctly, and a colour that has slipped
    /// under its contrast floor lays out perfectly — it just cannot be read. The
    /// light console shipped `faint` at 2.13:1 and `fault` at 1.72:1 for its
    /// entire life, through every one of these self-tests, because nothing was
    /// looking.
    ///
    /// Four things are asserted, and the last two are the ones that catch drift
    /// rather than typos:
    ///  - every token clears its own floor against the surface;
    ///  - the lamps stay far enough apart in LIGHTNESS to be told apart at 9px;
    ///  - the ink ramp stays ORDERED — ink more legible than secondary, than
    ///    muted, than hint. A single warmed hex can silently invert two tiers,
    ///    and an inverted ramp is a hierarchy that lies;
    ///  - `hint` outranks `faint`, which is the entire point of having split
    ///    them. Re-merging them by accident is how the mushy key line comes back.
    /// Nothing a human reads carries an em dash, and every row can be read in
    /// full.
    ///
    /// Ruled 18 Aug, twice in one sentence: "there's no way to see the full
    /// message, the full error, or whatever message is silent for 2h. Get rid
    /// of the fucking em dash. Moreover, if I hover, show me the full message
    /// in a tooltip."
    ///
    /// A sweep of the RENDERED labels rather than a grep of the source, because
    /// the string that reaches the screen is usually assembled from two or three
    /// that do not contain the character on their own — which is also why a
    /// one-off fix to one constant would not have held. Log lines are
    /// deliberately out of scope: they are diagnostics, not copy, and the app's
    /// own log is the one place the dash still earns its keep.
    func copyDrill() {
        func words(in view: NSView) -> [String] {
            var found: [String] = []
            if let field = view as? NSTextField {
                let text = field.attributedStringValue.string
                if !text.isEmpty { found.append(text) }
            }
            view.subviews.forEach { found += words(in: $0) }
            return found
        }
        // A row whose message is longer than the column, which is the case the
        // hover exists for.
        let message = "silent for 2h, nothing written since it started this"
        let stalled = SessionRow(
            id: "stall", name: "a session name long enough to truncate against the callsign",
            aux: message, lamp: .fault, detail: message)
        showIdle(rows: [stalled, SessionRow(
            id: "ok", name: "quiet one", aux: "ok", lamp: .ready)])
        panel?.contentView?.layoutSubtreeIfNeeded()
        var seen = panel?.contentView.map { words(in: $0) } ?? []
        let gridRow = waitingRows.arrangedSubviews
            .compactMap { $0 as? GridRowView }
            .first { $0.identifier?.rawValue == "stall" }
        let gridTip = gridRow?.toolTip

        // The same row on the other face.
        showPastAgents(items: [PastAgentsList.Item(
            row: stalled, revivable: false, haystack: stalled.name)])
        panel?.contentView?.layoutSubtreeIfNeeded()
        seen += panel?.contentView.map { words(in: $0) } ?? []
        let listTip = pastList.toolTipsForTesting.first
        goHomeFromPastAgents()

        // And the copy that only appears when something goes wrong, which is
        // exactly the copy nobody re-reads.
        seen += [StateLegend.noWordsNotice, StateLegend.slowTranscriptionNote]
        let offenders = seen.filter { $0.contains("\u{2014}") }

        SelfTest.report("copy", [
            ("noEmDashOnScreen", offenders.isEmpty),
            // Named, so a failure says WHICH string rather than sending the
            // next reader back through every face by hand.
            ("offenders", offenders.isEmpty),
            ("theGridRowCarriesItsWholeMessage",
             gridTip?.contains(message) == true),
            ("theListRowCarriesItTheSameWay", listTip?.contains(message) == true),
            ("bothFacesSayTheSameThing", gridTip == listTip),
            // The name is in the hover too: it truncates against the callsign
            // column and was the other half of what could not be read.
            ("theHoverCarriesTheWholeName",
             gridTip?.contains("truncate against the callsign") == true),
        ])
        if !offenders.isEmpty {
            Permissions.log("selftest copy: em dashes in \(offenders.count) string(s): "
                + offenders.prefix(5).joined(separator: " | "))
        }
        showIdle(rows: [])
    }

    func contrastDrill() {
        let surface = StateLegend.Palette.surface
        var checks: [(String, Bool)] = []

        for token in StateLegend.contrastFloors {
            let ratio = StateLegend.Measure.contrast(token.ink, surface)
            checks.append(("\(token.name)≥\(token.floor)", ratio >= token.floor))
            Permissions.log(String(
                format: "contrast: %@ = %.2f:1 (floor %.1f) L*=%.1f",
                token.name, ratio, token.floor,
                StateLegend.Measure.lightness(token.ink)))
        }

        let lampGap = StateLegend.Measure.lightnessGap(
            StateLegend.Palette.ready, StateLegend.Palette.working)
        checks.append(("lampΔL*≥\(StateLegend.lampLightnessFloor)",
                       lampGap >= StateLegend.lampLightnessFloor))

        // Ready is the rare lamp that wants you; working is the common one that
        // is only news. On a dark ground that ordering is expressible, and the
        // busy panel was ruled on it — so it is worth defending.
        let readyOutshinesWorking =
            StateLegend.Measure.contrast(StateLegend.Palette.ready, surface)
            > StateLegend.Measure.contrast(StateLegend.Palette.working, surface)
        checks.append(("readyOutshinesWorking", readyOutshinesWorking))

        let ramp = [StateLegend.Palette.ink, StateLegend.Palette.secondary,
                    StateLegend.Palette.muted, StateLegend.Palette.hint]
            .map { StateLegend.Measure.contrast($0, surface) }
        checks.append(("inkRampOrdered", zip(ramp, ramp.dropFirst()).allSatisfy { $0 > $1 }))

        checks.append(("hintOutranksFaint",
                       StateLegend.Measure.contrast(StateLegend.Palette.hint, surface)
                       > StateLegend.Measure.contrast(StateLegend.Palette.faint, surface)))

        // The tick is punched out of the lamp, not the panel, so it is the one
        // pair here measured against something other than the surface. It was a
        // hardcoded near-white until 09 Aug and would have gone invisible at
        // 1.88:1 on the brighter green.
        checks.append(("checkmarkOnReady≥3",
                       StateLegend.Measure.contrast(surface, StateLegend.Palette.ready) >= 3.0))

        Permissions.log(String(format: "contrast: lamp ΔL* = %.1f", lampGap))
        SelfTest.report("contrast", checks)
    }
}
