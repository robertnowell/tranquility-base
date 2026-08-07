import Foundation
import XCTest
@testable import TranquilityCore

/// The persisted cast: missing file seeds the original roster, a saved order
/// round-trips, and a deliberately emptied roster stays empty.
final class VoiceRosterTests: XCTestCase {

    private var savedURL: URL!

    override func setUp() {
        super.setUp()
        savedURL = VoiceRoster.fileURL
        VoiceRoster.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roster-\(UUID().uuidString).json")
    }

    override func tearDown() {
        VoiceRoster.fileURL = savedURL
        super.tearDown()
    }

    func testMissingFileSeedsTheOriginalCast() {
        XCTAssertEqual(VoiceRoster.load(), VoiceRoster.seed)
    }

    func testSavedOrderRoundTrips() {
        let reordered = Array(VoiceRoster.seed.reversed().prefix(3))
        VoiceRoster.save(reordered)
        XCTAssertEqual(VoiceRoster.load(), reordered)
    }

    func testEmptiedRosterStaysEmpty() {
        // [] is a decision, not an accident — it must not resurrect the seed.
        VoiceRoster.save([])
        XCTAssertEqual(VoiceRoster.load(), [])
    }
}
