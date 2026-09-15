import XCTest
@testable import TranquilityCore

/// The rule behind "Control worked, Option worked, both together did
/// nothing" (14 Sep 2026). Every case is a release the monitor has to
/// classify without knowing what the keys mean.
final class ChordReleaseTests: XCTestCase {

    private let threshold: TimeInterval = 0.20

    /// The report itself: ⌃⌥ pressed the way a person presses a chord they
    /// were just told about, held for most of a second.
    func testATwoModifierChordCountsAtAnyLength() {
        for held in [0.05, 0.19, 0.20, 0.6, 1.5, 4.0] {
            XCTAssertEqual(ChordRelease.verdict(modifiers: 2, duration: held,
                                                holdThreshold: threshold, interfered: false),
                           .fires, "held \(held)s")
        }
    }

    /// The hold threshold still governs a lone modifier: ⌥ held past it was a
    /// reply, ⌃ held past it is nothing, and neither release is a tap.
    func testALoneModifierHeldPastTheWindowIsNotATap() {
        XCTAssertEqual(ChordRelease.verdict(modifiers: 1, duration: 0.19,
                                            holdThreshold: threshold, interfered: false), .fires)
        XCTAssertEqual(ChordRelease.verdict(modifiers: 1, duration: 0.20,
                                            holdThreshold: threshold, interfered: false), .heldPastTap)
        XCTAssertEqual(ChordRelease.verdict(modifiers: 1, duration: 2.0,
                                            holdThreshold: threshold, interfered: false), .heldPastTap)
    }

    /// A key or a click inside the press outranks everything: ⌃⌥ plus a
    /// letter is somebody else's shortcut however long or short it was.
    func testInterferenceWinsOverLength() {
        for modifiers in [1, 2, 3] {
            for held in [0.05, 1.0] {
                XCTAssertEqual(ChordRelease.verdict(modifiers: modifiers, duration: held,
                                                    holdThreshold: threshold, interfered: true),
                               .interfered)
            }
        }
    }
}
