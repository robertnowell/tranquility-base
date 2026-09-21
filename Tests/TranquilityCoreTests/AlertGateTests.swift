import XCTest
@testable import TranquilityCore

/// The rule from 19 Sep: nobody sees the same alert twice in a row inside
/// the window, and a process with no feed gets no updater.
final class AlertGateTests: XCTestCase {

    func testFirstShowingIsAdmitted() {
        var gate = AlertGate()
        XCTAssertEqual(gate.admit("permission.microphone", at: Date(timeIntervalSince1970: 1000)), .show)
    }

    func testRepeatInsideWindowIsWithheld() {
        var gate = AlertGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = gate.admit("updates.start", at: t0)
        XCTAssertEqual(gate.admit("updates.start", at: t0.addingTimeInterval(84)),
                       .withheld(secondsAgo: 84))
        // Ten dialogs in fourteen minutes, the 19 Sep shape, starting fresh:
        // one per window, so two, not ten.
        var fresh = AlertGate()
        var shown = 0
        for i in 0..<10 where fresh.admit("updates.start", at: t0.addingTimeInterval(Double(i) * 84)) == .show {
            shown += 1
        }
        XCTAssertEqual(shown, 2, "one per ten-minute window across fourteen minutes")
    }

    func testRepeatAfterWindowShowsAgain() {
        var gate = AlertGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = gate.admit("k", at: t0)
        XCTAssertEqual(gate.admit("k", at: t0.addingTimeInterval(AlertGate.window)), .show)
    }

    func testWithheldRepeatDoesNotExtendTheWindow() {
        // A steady drip surfaces once per window, not never.
        var gate = AlertGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = gate.admit("k", at: t0)
        _ = gate.admit("k", at: t0.addingTimeInterval(AlertGate.window - 1))
        XCTAssertEqual(gate.admit("k", at: t0.addingTimeInterval(AlertGate.window + 1)), .show)
    }

    func testKeysAreIndependent() {
        var gate = AlertGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = gate.admit("a", at: t0)
        XCTAssertEqual(gate.admit("b", at: t0), .show)
    }

    func testClockGoingBackwardsNeverWithholds() {
        var gate = AlertGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = gate.admit("k", at: t0)
        XCTAssertEqual(gate.admit("k", at: t0.addingTimeInterval(-30)), .show)
    }

    func testHistoryRoundTrips() {
        var gate = AlertGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = gate.admit("k", at: t0)
        var restored = AlertGate(lastShown: gate.lastShown)
        XCTAssertEqual(restored.admit("k", at: t0.addingTimeInterval(5)), .withheld(secondsAgo: 5),
                       "a repeat from a fresh process is still a repeat")
    }

    /// The test process has no Info.plist worth the name and no `SUFeedURL`,
    /// exactly like `.build/debug/TranquilityApp`: it must get no updater,
    /// whatever the old-bundle fallback for `TBUpdatesEnabled` says.
    func testNoFeedMeansNoUpdater() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"))
        XCTAssertFalse(AppIdentity.updatesEnabled)
        XCTAssertTrue(AppIdentity.updatesDisabledReason.contains("SUFeedURL"))
    }
}
