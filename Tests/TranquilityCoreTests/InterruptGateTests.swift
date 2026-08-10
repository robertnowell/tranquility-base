import XCTest
@testable import TranquilityCore

/// The interrupt gate's order, and what it stopped being.
///
/// Two courtesy checks lived in this gate and both are gone with the spoken
/// callsign they protected (docs/ruling-the-return-is-a-sound-not-a-sentence.md):
/// first one that opened the microphone and listened to the room, then one that
/// asked the HAL which app was using audio. What survives is the part that was
/// always cheap and always right — refuse on a locked screen, refuse to a call
/// in front, refuse while the user is mid-keystroke.
final class InterruptGateTests: XCTestCase {

    private func gate(locked: Bool = false, front: String? = nil,
                      idle: Double = 1000) -> InterruptGate {
        InterruptGate(minimumIdleSeconds: 8, signals: .init(
            idleSeconds: { idle }, frontmostApp: { front }, screenLocked: { locked }))
    }

    func testLockedScreenRefuses() {
        let decision = gate(locked: true).evaluate()
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "screen is locked")
    }

    func testMutedAppInFrontRefuses() {
        XCTAssertEqual(gate(front: "zoom.us").evaluate().reason, "muted app in front: zoom.us")
    }

    /// A locked screen is answered before anything else is consulted, which is
    /// the ordering rule the gate has always had.
    func testLockedScreenOutranksTheFrontmostApp() {
        XCTAssertEqual(gate(locked: true, front: "zoom.us").evaluate().reason,
                       "screen is locked")
    }

    func testActivelyTypingRefuses() {
        let decision = gate(idle: 0).evaluate()
        XCTAssertFalse(decision.allowed)
        XCTAssertTrue(decision.reason.contains("actively typing"), decision.reason)
    }

    func testQuiescentSignalsAllow() {
        let decision = InterruptGate(minimumIdleSeconds: 0, signals: .quiescent).evaluate()
        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.reason, "no veto")
    }

    /// A keypress is never gated: you cannot interrupt someone who has just
    /// asked for something. The gate is consulted only for unprompted surfacing.
    func testTheGateIsAVetoAndNeverATrigger() {
        XCTAssertFalse(gate(locked: true).evaluate().allowed)
        XCTAssertFalse(gate(front: "FaceTime").evaluate().allowed)
        XCTAssertTrue(gate().evaluate().allowed)
    }
}
