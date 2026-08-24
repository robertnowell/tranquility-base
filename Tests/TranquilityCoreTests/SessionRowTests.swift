import XCTest
@testable import TranquilityCore

/// The session grid's data model and pure logic, extracted from the app
/// layer (App-lane P6, 24 Aug) specifically so the real behavioral rules
/// it encodes — what a tap does, what a lamp click does, which rows the
/// grid draws — could finally be asserted without a window server. None
/// of this had any coverage before; `Sources/TranquilityApp` has none and
/// cannot easily have any (CLAUDE.md rule 7).
final class SessionRowTests: XCTestCase {

    private func row(id: String = "a1b2c3d4e5", lamp: Lamp = .ready, revivable: Bool = false,
                     switchedOff: Bool = false, aux: String = "aux", detail: String? = nil
    ) -> SessionRow {
        SessionRow(id: id, name: "name", aux: aux, lamp: lamp,
                  revivable: revivable, switchedOff: switchedOff, detail: detail)
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

    func testTapOnLiveRowsAnnounces() {
        for lamp: Lamp in [.ready, .working, .running] {
            XCTAssertEqual(SessionRow.action(for: row(lamp: lamp)), .announce)
        }
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

    func testQuietRowsLastOrdersLitThenRunningThenUnlitThenSwitchedOff() {
        let ready = row(id: "ready1", lamp: .ready)
        let running = row(id: "running1", lamp: .running)
        let unlit = row(id: "unlit1", lamp: .unlit)
        let off = row(id: "off1", lamp: .ready, switchedOff: true)
        // Deliberately scrambled input — the function must do the sorting,
        // not merely preserve an already-correct order.
        let ordered = SessionRow.quietRowsLast([off, unlit, running, ready])
        XCTAssertEqual(ordered.map(\.id), ["ready1", "running1", "unlit1", "off1"],
                       "switched-off sinks below even dead rows")
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
