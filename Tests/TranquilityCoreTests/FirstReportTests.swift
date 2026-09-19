import XCTest
@testable import TranquilityCore

/// The flag behind the one report that is allowed to take the screen.
final class FirstReportTests: XCTestCase {
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        store = UserDefaults(suiteName: "first-report-test-\(UUID().uuidString)")!
        FirstReport.defaults = store
    }
    override func tearDown() { FirstReport.defaults = .standard; super.tearDown() }

    /// Absent means on. The machine that has never thought about this is the
    /// new machine, which is exactly the one this exists for.
    func testAMachineThatHasNeverThoughtAboutItIsPending() {
        XCTAssertTrue(FirstReport.pending)
    }

    func testSpendingItIsPermanent() {
        FirstReport.spent()
        XCTAssertFalse(FirstReport.pending)
        // A second call is not an error and does not undo anything.
        FirstReport.spent()
        XCTAssertFalse(FirstReport.pending)
    }

    /// For the switch in Setup, and for the day the hub says it is installed
    /// as an app, where taking a browser tab is the wrong move entirely.
    func testItCanBeTurnedOffAndBackOn() {
        FirstReport.set(false)
        XCTAssertFalse(FirstReport.pending)
        FirstReport.set(true)
        XCTAssertTrue(FirstReport.pending)
    }
}
