import XCTest
@testable import TranquilityCore

/// The Past Agents column's own vocabulary. Every case here is a sentence a
/// row can actually print, and the two that matter are the boundary (where the
/// column stops counting and starts dating) and the backwards clock.
final class LastMovedLabelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_755_648_000)  // 2026-08-19 20:00 UTC

    private func label(minusSeconds s: TimeInterval) -> String {
        SessionActivity.lastMovedLabel(now.addingTimeInterval(-s), now: now)
    }

    func testFreshReadsAsNow() {
        XCTAssertEqual(label(minusSeconds: 0), "now")
        XCTAssertEqual(label(minusSeconds: 59), "now")
    }

    func testMinutesThenHours() {
        XCTAssertEqual(label(minusSeconds: 22 * 60), "22m ago")
        // `spoken` counts in minutes until 90, which is deliberate and inherited.
        XCTAssertEqual(label(minusSeconds: 89 * 60), "89m ago")
        XCTAssertEqual(label(minusSeconds: 5 * 3600), "5h ago")
        XCTAssertEqual(label(minusSeconds: 23 * 3600), "23h ago")
    }

    /// The ruling this function exists for: past two days a person navigates by
    /// date, so the column stops offering a duration to do arithmetic on.
    func testTwoDaysIsTheCutoff() {
        XCTAssertEqual(label(minusSeconds: 47 * 3600), "47h ago")
        XCTAssertEqual(label(minusSeconds: 48 * 3600), "Aug 17")
        XCTAssertEqual(label(minusSeconds: 5 * 86_400), "Aug 14")
    }

    /// A "d" would mean the cutoff leaked: `spoken` produces days past 48h and
    /// this column must never reach that branch.
    func testNeverSaysDays() {
        for days in 2...30 {
            let out = label(minusSeconds: Double(days) * 86_400)
            XCTAssertFalse(out.hasSuffix("d ago"), "\(days)d printed \(out)")
        }
    }

    /// A transcript stamped in the future (an NTP step mid-scan) must not print
    /// a tense the column has no words for.
    func testClockRunningBackwardsSaysNow() {
        XCTAssertEqual(SessionActivity.lastMovedLabel(now.addingTimeInterval(600), now: now), "now")
    }
}
