import Foundation
import XCTest
@testable import TranquilityCore

/// The switch is a set and one rule, and the rule is the part worth testing.
///
/// Ruled 18 Aug: the user turns a lamp off, the panel never does. That makes
/// `isOff` the only place where a session the user filed can come back on its
/// own — so the exception it encodes (a WAITING turn overrides the switch, work
/// and faults do not) is the whole design, and the two halves fail in opposite
/// directions. Too eager and the switch is undone within seconds by the work the
/// user just said they did not want to watch; too strict and a panel whose
/// entire job is "who needs you" hides an agent that needs you.
final class LampSwitchTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-off-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    // MARK: - The rule

    func testASessionNobodySwitchedOffIsOn() {
        XCTAssertFalse(LampSwitch.isOff("a", waiting: false, switchedOff: []))
        XCTAssertFalse(LampSwitch.isOff("a", waiting: true, switchedOff: ["b"]))
    }

    func testSwitchedOffStaysOffWhileItHasNothingToAsk() {
        XCTAssertTrue(LampSwitch.isOff("a", waiting: false, switchedOff: ["a"]))
    }

    /// The exception. Green is the needs-you channel; a panel that hides it
    /// because the session was filed an hour ago has lost the user's work for
    /// them. One click files it again.
    func testAWaitingTurnTurnsTheLampBackOn() {
        XCTAssertFalse(LampSwitch.isOff("a", waiting: true, switchedOff: ["a"]))
    }

    /// The other half, and the one that would quietly destroy the feature.
    /// A working session writes constantly; if activity re-lit the switch, an
    /// agent would be back on the grid before the user's finger left the mouse.
    func testWorkAndFaultsDoNotUndoTheSwitch() {
        // `waiting` is the ONLY input, on purpose: there is deliberately no
        // parameter here for blue or amber to arrive through. A future edit
        // that wants one has to come back and read the note above.
        XCTAssertTrue(LampSwitch.isOff("a", waiting: false, switchedOff: ["a"]))
    }

    // MARK: - The set

    func testTurnOffThenOnRoundTripsThroughTheFile() {
        LampSwitch.turnOff("a", at: url)
        LampSwitch.turnOff("b", at: url)
        XCTAssertEqual(LampSwitch.load(from: url), ["a", "b"])

        LampSwitch.turnOn("a", at: url)
        XCTAssertEqual(LampSwitch.load(from: url), ["b"])
    }

    /// The reason this is persisted at all: a click the next launch forgets is
    /// worse than no switch, because the panel comes back full of rows the user
    /// already dealt with and the gesture reads as broken.
    func testTheSwitchSurvivesARestart() {
        LampSwitch.turnOff("a", at: url)
        XCTAssertTrue(LampSwitch.isOff("a", waiting: false,
                                       switchedOff: LampSwitch.load(from: url)))
    }

    func testAMissingFileIsAnEmptySetRatherThanAFailure() {
        XCTAssertEqual(LampSwitch.load(from: url), [])
    }

    func testAGarbledFileIsAnEmptySetRatherThanACrash() {
        try? Data("not json".utf8).write(to: url)
        XCTAssertEqual(LampSwitch.load(from: url), [])
    }

    /// Stable on disk, so a diff of the support directory is readable and a bug
    /// report that quotes this file quotes the same thing twice running.
    func testTheFileIsWrittenInAStableOrder() {
        LampSwitch.save(["c", "a", "b"], to: url)
        let first = try? String(contentsOf: url, encoding: .utf8)
        LampSwitch.save(["b", "c", "a"], to: url)
        XCTAssertEqual(first, try? String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(first, #"["a","b","c"]"#)
    }

    func testPruneDropsSessionsThePanelCanNoLongerSee() {
        LampSwitch.save(["gone", "here"], to: url)
        XCTAssertEqual(LampSwitch.prune(keeping: ["here", "other"], at: url), ["here"])
        XCTAssertEqual(LampSwitch.load(from: url), ["here"])
    }
}
