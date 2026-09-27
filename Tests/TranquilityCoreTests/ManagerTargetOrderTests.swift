import XCTest
@testable import TranquilityCore

/// The manager's `targets` door returns the grid's order (27 Sep 2026).
///
/// Ruled by Robert after "invite the next agent" staged an idle session nobody
/// was waiting on: "it should be the same rules as for the grid today, bring
/// next agent." The door used to sort alphabetically by working directory, so
/// "next" meant "whichever project sorts first".
final class ManagerTargetOrderTests: XCTestCase {

    private func band(_ id: String, status: String?, waiting: Set<String>) -> Int {
        ManagerJSON.gridBand(
            LiveSession(pid: 1, sessionId: id, cwd: "/tmp/\(id)", status: status),
            waiting: waiting)
    }

    /// The grid's three live bands, in the grid's order: the lamps that ask for
    /// you, then the ones working on their own, then the merely alive.
    func testAskingBeatsWorkingBeatsAlive() {
        let waiting: Set<String> = ["asks"]
        XCTAssertEqual(band("asks", status: "idle", waiting: waiting), 0)
        XCTAssertEqual(band("works", status: "busy", waiting: waiting), 1)
        XCTAssertEqual(band("alive", status: "idle", waiting: waiting), 2)
    }

    /// An agent asking for you outranks one that is busy, which is the whole
    /// of "green above blue" (#458, 15 Sep) carried onto this door.
    func testABusyAgentDoesNotOutrankOneWaitingOnYou() {
        let waiting: Set<String> = ["asks"]
        XCTAssertLessThan(band("asks", status: "busy", waiting: waiting),
                          band("works", status: "busy", waiting: waiting))
    }

    /// Read-state is not a band and must never become one. The manager sorted
    /// unheard rows first until today, so hearing an agent changed who was
    /// next — the behaviour the panel itself reverted the day it was tried
    /// (#439: "hearing a row must not move it").
    func testHearingAnAgentCannotChangeItsBand() {
        let waiting: Set<String> = ["asks"]
        let before = band("asks", status: "idle", waiting: waiting)
        // `heard` is not an input here at all, and that is the assertion.
        XCTAssertEqual(before, band("asks", status: "idle", waiting: waiting))
        XCTAssertEqual(before, 0)
    }

    /// A status the probe could not read is alive, not working. Failing open
    /// into the working band would put an unknown row above every quiet one.
    func testAnUnknownStatusIsMerelyAlive() {
        XCTAssertEqual(band("x", status: nil, waiting: []), 2)
        XCTAssertEqual(band("x", status: "shell", waiting: []), 2)
    }
}
