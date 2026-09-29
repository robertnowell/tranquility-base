import XCTest
@testable import TranquilityCore

/// 28 Sep: every read of secrets.json was traced, twice a second, 757 lines in
/// six and a half minutes. A read is logged when its outcome changes.
final class SecretsReadLogTests: XCTestCase {
    func testARepeatedOutcomeIsLoggedOnce() {
        let log = Secrets.ChangeLog()
        var lines: [String] = []
        let sink: (String) -> Void = { lines.append($0) }
        for _ in 0..<50 { log.note("read /s.json -> keys [\"a\", \"b\"]", to: sink) }
        XCTAssertEqual(lines.count, 1)
    }

    func testAFailureARecoveryAndANewKeyAllStillPrint() {
        let log = Secrets.ChangeLog()
        var lines: [String] = []
        let sink: (String) -> Void = { lines.append($0) }
        log.note("read /s.json -> keys [\"a\"]", to: sink)
        log.note("read failed at /s.json: gone", to: sink)
        log.note("read failed at /s.json: gone", to: sink)
        log.note("read /s.json -> keys [\"a\"]", to: sink)
        log.note("read /s.json -> keys [\"a\", \"b\"]", to: sink)
        XCTAssertEqual(lines, [
            "read /s.json -> keys [\"a\"]",
            "read failed at /s.json: gone",
            "read /s.json -> keys [\"a\"]",
            "read /s.json -> keys [\"a\", \"b\"]",
        ])
    }
}
