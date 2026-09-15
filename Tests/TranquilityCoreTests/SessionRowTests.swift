import XCTest
@testable import TranquilityCore

/// The session grid's data model and pure logic, extracted from the app
/// layer (App-lane P6, 24 Aug) specifically so the real behavioral rules
/// it encodes — what a tap does, what a lamp click does, which rows the
/// grid draws — could finally be asserted without a window server. None
/// of this had any coverage before; `Sources/TranquilityApp` has none and
/// cannot easily have any (CLAUDE.md rule 7).
final class SessionRowTests: XCTestCase {

    /// A green fixture carries an unread turn, because that is what a green
    /// LOCAL row always has: band 1 stamps `.unread` or `.opened` and nothing
    /// else builds one. A green row with `read: .none` is a remote agent that
    /// has never spoken, and since 15 Sep it does not announce (there is
    /// nothing in the store to read out). The fixtures used to build green
    /// rows with no read state and assert they announced — describing a row
    /// production never makes, and hiding the one it does.
    private func row(id: String = "a1b2c3d4e5", lamp: Lamp = .ready, revivable: Bool = false,
                     switchedOff: Bool = false, aux: String = "aux", detail: String? = nil,
                     read: ReadState? = nil
    ) -> SessionRow {
        SessionRow(id: id, name: "name", aux: aux, lamp: lamp,
                   revivable: revivable, read: read ?? (lamp == .ready ? .unread : .none),
                   switchedOff: switchedOff, detail: detail)
    }

    // MARK: - Lamp

    func testOnlyReadyWorkingFaultAreLit() {
        XCTAssertTrue(Lamp.ready.isLit)
        XCTAssertTrue(Lamp.working.isLit)
        XCTAssertTrue(Lamp.fault.isLit)
        XCTAssertFalse(Lamp.running.isLit, "alive with nothing in flight is off, not a fourth color")
        XCTAssertFalse(Lamp.unlit.isLit)
    }

    func testOnlyReadyAndFaultAskForYou() {
        // working is MIL-STD-411's advisory channel — news, not a question.
        XCTAssertTrue(Lamp.ready.asksForYou)
        XCTAssertTrue(Lamp.fault.asksForYou)
        XCTAssertFalse(Lamp.working.asksForYou)
        XCTAssertFalse(Lamp.running.asksForYou)
        XCTAssertFalse(Lamp.unlit.asksForYou)
    }

    // MARK: - RowAction: what a tap does

    func testTapOnFaultGoesToAgent() {
        XCTAssertEqual(SessionRow.action(for: row(lamp: .fault)), .goToAgent)
    }

    func testTapOnWorkingGoesToAgent() {
        // Blue joined amber on 24 Aug: a row with work in hand has no
        // unread turn, so the announcement has nothing to say. The door
        // does — the pane is already writing what a summary would
        // paraphrase.
        XCTAssertEqual(SessionRow.action(for: row(lamp: .working)), .goToAgent)
    }

    func testTapOnQuietGoesToAgent() {
        // The dark lamp joined them the same day. Its turn is complete and
        // already heard, so announce had nothing left to read and fell
        // through to nothingWaiting — a tap that logged a line and did
        // nothing. Three lamps, three reasons, one verb.
        XCTAssertEqual(SessionRow.action(for: row(lamp: .running)), .goToAgent)
    }

    func testGreenIsTheOnlyLampThatAnnounces() {
        // The whole rule in one assertion: announce is for a row with an
        // unread turn, and green is the only lamp that has one.
        for lamp: Lamp in [.ready, .working, .running, .fault] {
            let expected: SessionRow.RowAction = lamp == .ready ? .announce : .goToAgent
            XCTAssertEqual(SessionRow.action(for: row(lamp: lamp)), expected,
                           "\(lamp) took the wrong verb")
        }
    }

    func testQuietRowIsStillLive() {
        XCTAssertTrue(SessionRow.isLive(row(lamp: .running)))
    }

    func testWorkingRowIsStillLive() {
        // Its verb changed; its liveness did not. END SESSION and the row
        // menu both hang off isLive, and they must not have quietly gone
        // away with the announcement.
        XCTAssertTrue(SessionRow.isLive(row(lamp: .working)))
    }

    func testTapOnRevivableDeadRowRevives() {
        XCTAssertEqual(SessionRow.action(for: row(lamp: .unlit, revivable: true)), .revive)
    }

    func testTapOnUnprovenDeadRowDoesNothing() {
        // Doing nothing is the correct outcome for an unproven-dead row —
        // resuming a session that's actually still alive puts two
        // processes under one id, which crashed the app twice.
        XCTAssertEqual(SessionRow.action(for: row(lamp: .unlit, revivable: false)), .none)
    }

    func testIsLiveMatchesAnnounceAndGoToAgentOnly() {
        XCTAssertTrue(SessionRow.isLive(row(lamp: .ready)))
        XCTAssertTrue(SessionRow.isLive(row(lamp: .fault)))
        XCTAssertFalse(SessionRow.isLive(row(lamp: .unlit, revivable: true)),
                       "revive is not live — there is no process to speak to yet")
        XCTAssertFalse(SessionRow.isLive(row(lamp: .unlit, revivable: false)))
    }

    // MARK: - LampAction: what a lamp click does

    func testLampClickOnGridTurnsOffAnyLitOrQuietRow() {
        for lamp: Lamp in [.ready, .working, .running, .fault] {
            XCTAssertEqual(SessionRow.lampAction(for: row(lamp: lamp), on: .grid), .turnOff)
        }
    }

    func testLampClickOnListTurnsOnAnyLitOrQuietRow() {
        for lamp: Lamp in [.ready, .working, .running, .fault] {
            XCTAssertEqual(SessionRow.lampAction(for: row(lamp: lamp), on: .list), .turnOn)
        }
    }

    func testLampClickOnADeadRowAlwaysRevivesRegardlessOfFace() {
        // Deliberately not gated on `revivable` here — `revive()` itself
        // re-probes and refuses safely with a reason.
        XCTAssertEqual(SessionRow.lampAction(for: row(lamp: .unlit), on: .grid), .revive)
        XCTAssertEqual(SessionRow.lampAction(for: row(lamp: .unlit), on: .list), .revive)
    }

    // MARK: - quietRowsLast: the three (four) bands

    func testQuietRowsLastOrdersLitThenRunningThenSwitchedOffThenUnlit() {
        let ready = row(id: "ready1", lamp: .ready)
        let running = row(id: "running1", lamp: .running)
        let unlit = row(id: "unlit1", lamp: .unlit)
        let off = row(id: "off1", lamp: .ready, switchedOff: true)
        // Deliberately scrambled input — the function must do the sorting,
        // not merely preserve an already-correct order.
        let ordered = SessionRow.quietRowsLast([off, unlit, running, ready])
        XCTAssertEqual(ordered.map(\.id), ["ready1", "running1", "off1", "unlit1"],
                       "a switched-off row is alive, so it outranks a dead one")
    }

    /// The 29 Aug reversal, stated as the thing the user could see: a session
    /// he had just switched off was at the BOTTOM of Past Agents, under every
    /// dead row on the list. Both bands are quiet and neither is on the grid,
    /// so this ordering is the entire difference between the two on screen.
    func testASwitchedOffRowOutranksEveryDeadRow() {
        let dead = (1...3).map { row(id: "dead\($0)", lamp: .unlit, revivable: true) }
        let off = row(id: "filed", lamp: .running, switchedOff: true)
        let ordered = SessionRow.quietRowsLast(dead + [off])
        XCTAssertEqual(ordered.first?.id, "filed",
                       "switched off by hand is still a session you can speak to")
        XCTAssertEqual(ordered.map(\.id), ["filed", "dead1", "dead2", "dead3"],
                       "and the dead keep their own order behind it")
    }

    func testQuietRowsLastIsAStablePartitionWithinABand() {
        // Two `.ready` rows: their relative order must survive untouched —
        // the caller has already established recency and a comparator
        // that reshuffled ties would silently spend that ordering.
        let first = row(id: "first", lamp: .ready)
        let second = row(id: "second", lamp: .ready)
        let ordered = SessionRow.quietRowsLast([first, second])
        XCTAssertEqual(ordered.map(\.id), ["first", "second"])
    }

    /// The 14 Sep reversal of #428, stated as the thing the user could see: he
    /// heard a row and it moved down the grid, under every unread one. The
    /// caller orders lit rows by recency; hearing one changes its weight on
    /// screen and nothing else.
    func testAHeardGreenRowKeepsItsPlaceAboveAnUnreadOne() {
        let heard = SessionRow(id: "heard", name: "heard", aux: "aux", lamp: .ready,
                               read: .opened)
        let unread = SessionRow(id: "unread", name: "unread", aux: "aux", lamp: .ready,
                                read: .unread)
        let amber = SessionRow(id: "amber", name: "amber", aux: "aux", lamp: .fault)
        let ordered = SessionRow.quietRowsLast([heard, unread, amber])
        XCTAssertEqual(ordered.map(\.id), ["heard", "unread", "amber"],
                       "lit rows keep the recency order they arrived in, read or not")
    }

    /// The panel's `quietRowsDrill`, mirrored. That drill shipped red twice on
    /// 14 Sep because the panel has no unit tests and nobody re-ran it; this
    /// is the same fixture, so the next drift fails here first.
    func testTheQuietRowsDrillFixtureHoldsInTheSuite() {
        func row(_ id: String, _ lamp: Lamp) -> SessionRow {
            SessionRow(id: id, name: id, aux: id, lamp: lamp)
        }
        let mixed = [row("w1", .working), row("i1", .running), row("d1", .unlit),
                     row("r1", .ready), row("i2", .running), row("d2", .unlit),
                     row("f1", .fault), row("w2", .working)]
        let sorted = SessionRow.quietRowsLast(mixed).map(\.id)
        XCTAssertEqual(sorted, ["r1", "f1", "w1", "w2", "i1", "i2", "d1", "d2"],
                       "asks-for-you, then blue, each in arrival order; then quiet, then closed")
    }

    // MARK: - Green above blue (ruled 15 Sep 2026)

    /// Robert, on the screenshot #458 produced: "the green lamps should
    /// always be above the blue lamps." A working session writes its
    /// transcript every few seconds, so on a pure recency sort it is always
    /// the newest row on the panel; the blue here is newer than every green
    /// by a wide margin and must still sit under all of them.
    func testBlueSitsBelowEveryGreenHoweverRecentItIs() {
        let sorted = SessionRow.quietRowsLast([
            lit("blue-now", 0, lamp: .working),
            lit("green-yesterday", 16 * 3600),
            lit("green-this-morning", 5 * 3600),
        ]).map(\.id)
        XCTAssertEqual(sorted, ["green-this-morning", "green-yesterday", "blue-now"])
    }

    /// Amber is the other channel that asks (`Lamp.asksForYou`), and it sits
    /// WITH green rather than above it: which of the two asked most recently
    /// is the order that matters. Blue orders among itself the same way.
    func testTheAskingTierAndTheBlueTierEachOrderByRecency() {
        let sorted = SessionRow.quietRowsLast([
            lit("blue-old", 300, lamp: .working),
            lit("amber", 60, lamp: .fault),
            lit("blue-new", 10, lamp: .working),
            lit("green", 30),
        ]).map(\.id)
        XCTAssertEqual(sorted, ["green", "amber", "blue-new", "blue-old"])
    }

    // MARK: - gridRows / shownCount: the grid's own membership

    func testShownCountIsAtLeastTheFloorOnAQuietMachine() {
        let rows = [row(id: "a", lamp: .unlit)]
        XCTAssertEqual(SessionRow.shownCount(rows, capacity: 20, floor: 8), 8,
                       "the floor holds even with nothing lit")
    }

    func testShownCountGrowsWithLitCountUpToCapacity() {
        let lit = (0..<15).map { row(id: "lit\($0)", lamp: .ready) }
        XCTAssertEqual(SessionRow.shownCount(lit, capacity: 20, floor: 8), 15)
        XCTAssertEqual(SessionRow.shownCount(lit, capacity: 10, floor: 8), 10,
                       "capacity clamps even when more sessions are lit")
    }

    func testShownCountExcludesSwitchedOffFromTheLitCount() {
        let litButOff = [row(id: "a", lamp: .ready, switchedOff: true)]
        XCTAssertEqual(SessionRow.shownCount(litButOff, capacity: 20, floor: 8), 8,
                       "a switched-off row does not grow the panel's worth of slots")
    }

    func testGridRowsDrawsLitFirstThenAliveThenDeadWithinTheSlotBudget() {
        let ready = row(id: "ready1", lamp: .ready)
        let running = row(id: "running1", lamp: .running)
        let unlit = row(id: "unlit1", lamp: .unlit)
        // capacity/floor of 1: only one slot, and lit must win it even
        // though it's listed last in the input.
        let shown = SessionRow.gridRows([unlit, running, ready], capacity: 1, floor: 1)
        XCTAssertEqual(shown.map(\.id), ["ready1"])
    }

    func testGridRowsExcludesSwitchedOffEntirely() {
        let off = row(id: "off1", lamp: .ready, switchedOff: true)
        let ready = row(id: "ready1", lamp: .ready)
        let shown = SessionRow.gridRows([off, ready], capacity: 8, floor: 8)
        XCTAssertEqual(shown.map(\.id), ["ready1"],
                       "the switch's whole job is to make a session leave the grid by hand")
    }

    func testGridRowsBumpsADeadRowForAGenuinelyLiveIdleOneWhenSlotsAreTight() {
        // The 23 Aug reversal this pins: a dead test session must not hold
        // a floor slot while a genuinely live, idle (.running) session is
        // bumped to the list instead.
        let dead = row(id: "dead1", lamp: .unlit)
        let idle = row(id: "idle1", lamp: .running)
        let shown = SessionRow.gridRows([dead, idle], capacity: 1, floor: 1)
        XCTAssertEqual(shown.map(\.id), ["idle1"])
    }

    // MARK: - hoverText

    func testHoverTextIsJustTheNameWithNoDetailAndAuxIsTheShortId() {
        let r = row(aux: SessionRow.shortId("a1b2c3d4e5"), detail: nil)
        XCTAssertEqual(SessionRow.hoverText(for: r), "name")
    }

    func testHoverTextAppendsTheDetailWhenPresent() {
        let r = row(detail: "silent for 2h, no output")
        XCTAssertEqual(SessionRow.hoverText(for: r), "name\nsilent for 2h, no output")
    }

    func testHoverTextFallsBackToAuxWhenThereIsNoDetailButAuxIsntJustTheId() {
        let r = row(aux: "stopped on a usage limit", detail: nil)
        XCTAssertEqual(SessionRow.hoverText(for: r), "name\nstopped on a usage limit")
    }

    // MARK: - displayName / shortId

    func testDisplayNamePrefersLiveNameThenCallsignThenFallback() {
        XCTAssertEqual(SessionRow.displayName(liveName: "tab title", callsign: "cs", fallback: "fb"),
                       "tab title")
        XCTAssertEqual(SessionRow.displayName(liveName: nil, callsign: "cs", fallback: "fb"), "cs")
        XCTAssertEqual(SessionRow.displayName(liveName: "", callsign: "", fallback: "fb"), "fb")
    }

    func testShortIdIsTheLeadingEight() {
        XCTAssertEqual(SessionRow.shortId("a1b2c3d4e5f6"), "a1b2c3d4")
    }

    // MARK: - switchedOffCopy

    func testSwitchedOffCopyForcesTheLampToRunningAndFlagsIt() {
        let r = row(lamp: .fault, switchedOff: false)
        let copy = r.switchedOffCopy()
        XCTAssertEqual(copy.lamp, .running)
        XCTAssertTrue(copy.switchedOff)
        XCTAssertEqual(copy.id, r.id, "everything else about the row survives the copy")
    }

    // MARK: - ReadState

    func testOnlyUnreadIsAsking() {
        XCTAssertTrue(ReadState.unread.isAsking)
        XCTAssertFalse(ReadState.opened.isAsking)
        XCTAssertFalse(ReadState.none.isAsking)
    }
}

// MARK: - Lit rows order by recency (#454, ruled 14 Sep 2026)

extension SessionRowTests {

    private func lit(_ id: String, _ ago: TimeInterval?, lamp: Lamp = .ready) -> SessionRow {
        SessionRow(id: id, name: id, aux: "", lamp: lamp,
                   lastActivity: ago.map { Date(timeIntervalSinceNow: -$0) })
    }

    /// The whole point: newest first, whatever band enumerated it.
    func testLitRowsSortNewestFirst() {
        let sorted = SessionRow.quietRowsLast([
            lit("old", 900), lit("newest", 5), lit("middle", 60),
        ]).map(\.id)
        XCTAssertEqual(sorted, ["newest", "middle", "old"])
    }

    /// **The case that motivated it.** A remote row is enumerated last by
    /// construction, so before this it could never win a slot however recently
    /// it had spoken. Measured on the real panel beforehand: 0 of 12.
    func testARecentRemoteRowOutranksStaleLocalOnes() {
        let sorted = SessionRow.quietRowsLast([
            lit("local-old", 3600), lit("local-older", 7200),
            lit("remote-just-now", 2),          // arrives last, sorts first
        ]).map(\.id)
        XCTAssertEqual(sorted.first, "remote-just-now")
    }

    /// **Hearing a row must not move it** — Robert's own rule, and the reason
    /// the read-state ranking was reverted. Read-state bolds a row and drives
    /// the announcer; it does not order the grid.
    func testReadingARowDoesNotChangeItsPlace() {
        let before = SessionRow.quietRowsLast([
            lit("a", 10), lit("b", 20), lit("c", 30),
        ]).map(\.id)
        let afterReading = SessionRow.quietRowsLast([
            SessionRow(id: "a", name: "a", aux: "", lamp: .ready, read: .opened,
                       lastActivity: Date(timeIntervalSinceNow: -10)),
            lit("b", 20), lit("c", 30),
        ]).map(\.id)
        XCTAssertEqual(before, afterReading)
    }

    /// A band that cannot say when keeps its arrival place at the END of the
    /// lit rows. "I don't know" is not "never", and sorting it to 1970 would
    /// bury a live agent under every dated one.
    func testRowsWithNoTimestampKeepArrivalOrderAtTheEnd() {
        let sorted = SessionRow.quietRowsLast([
            lit("undated-first", nil), lit("dated", 100), lit("undated-second", nil),
        ]).map(\.id)
        XCTAssertEqual(sorted, ["dated", "undated-first", "undated-second"])
    }

    /// The partition is untouched: recency orders WITHIN the lit band only,
    /// and a quiet or dead row does not climb past a lit one by being recent.
    func testRecencyDoesNotDisturbTheLampPartition() {
        let sorted = SessionRow.quietRowsLast([
            SessionRow(id: "dead", name: "", aux: "", lamp: .unlit,
                       lastActivity: Date()),
            SessionRow(id: "quiet", name: "", aux: "", lamp: .running,
                       lastActivity: Date()),
            lit("lit", 9999),
        ]).map(\.id)
        XCTAssertEqual(sorted, ["lit", "quiet", "dead"])
    }

    /// Equal timestamps must not shuffle between repaints: `sorted(by:)` is
    /// not stable in Swift, so arrival is the tiebreak.
    func testEqualTimestampsKeepArrivalOrderEveryTime() {
        let at = Date()
        let rows = (1...6).map {
            SessionRow(id: "r\($0)", name: "", aux: "", lamp: .ready, lastActivity: at)
        }
        let expected = rows.map(\.id)
        for _ in 0..<50 {
            XCTAssertEqual(SessionRow.quietRowsLast(rows).map(\.id), expected)
        }
    }
}
