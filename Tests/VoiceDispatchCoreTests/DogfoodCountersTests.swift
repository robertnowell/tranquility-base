import XCTest
import GRDB
@testable import VoiceDispatchCore

/// WS-E groundwork: the append-only dogfood_event log and the computed counters.
final class DogfoodCountersTests: XCTestCase {

    private func makeStore() throws -> (QueueStore, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-dogfood-\(UUID().uuidString).sqlite")
        return (try QueueStore(url: tmp), tmp)
    }

    func testRecordAndQueryRoundtrip() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.recordDogfood(.announcementSpoken, sessionId: "s1")
        try store.recordDogfood(.announcementSpoken, sessionId: "s2")
        try store.recordDogfood(.terminalDropBack, sessionId: "s1",
                                note: "opened the tab to read the diff")
        try store.recordDogfood(.attributionError, note: "blamed kopi, was promotions")

        let counts = try store.dogfoodCounts(since: .distantPast)
        XCTAssertEqual(counts[.announcementSpoken], 2)
        XCTAssertEqual(counts[.terminalDropBack], 1)
        XCTAssertEqual(counts[.attributionError], 1)
        XCTAssertNil(counts[.replayRequested], "unrecorded kinds are absent, not zero")

        // The row carries its facts whole — this is the record WS-E queries later.
        let row = try store.dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT sessionId, note FROM dogfood_event WHERE kind = ?
                """, arguments: [DogfoodEventKind.terminalDropBack.rawValue])
        }
        XCTAssertEqual(row?["sessionId"], "s1")
        XCTAssertEqual(row?["note"], "opened the tab to read the diff")
    }

    func testSummaryWindowExcludesOlderEvents() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()

        try store.recordDogfood(.announcementSpoken, at: now.addingTimeInterval(-8 * 86_400))
        try store.recordDogfood(.announcementSpoken, at: now.addingTimeInterval(-3600))

        XCTAssertEqual(try store.dogfoodSummary(days: 7, now: now)
            .counts[.announcementSpoken], 1)
        XCTAssertEqual(try store.dogfoodSummary(days: 30, now: now)
            .counts[.announcementSpoken], 2)
    }

    func testActionabilityMath() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        for _ in 0..<4 { try store.recordDogfood(.announcementSpoken) }
        for _ in 0..<3 { try store.recordDogfood(.announcementActedOn) }

        let summary = try store.dogfoodSummary(days: 7)
        XCTAssertEqual(summary.actionability, 0.75)
    }

    func testActionabilityIsNilNotZeroWhenNothingWasSpoken() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(try store.dogfoodSummary().actionability, "0/0 is no data, not 0%")

        // Acted-on without spoken (clock skew, partial wiring) still divides by
        // spoken only — never by a denominator that was not recorded.
        try store.recordDogfood(.announcementActedOn)
        XCTAssertNil(try store.dogfoodSummary().actionability)
    }
}
