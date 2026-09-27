import Foundation
import XCTest
@testable import TranquilityCore

/// The manager's `notes` tool: everything said, found by time and by words.
final class ManagerNotesTests: XCTestCase {
    private func note(_ id: String, _ minutesAgo: Double, _ text: String, now: Date) -> ManagerNotes.Note {
        .init(id: id, at: now.addingTimeInterval(-minutesAgo * 60), source: "dictation", text: text, agent: nil)
    }

    func testAWindowKeepsTheNotesInsideItOldestFirst() {
        let now = Date()
        let all = [note("a", 90, "The deploy is slow.", now: now), note("b", 5, "Try the cache.", now: now),
                   note("c", 30, "Check the logs.", now: now)]
        let (got, matched) = ManagerNotes.select(all, query: nil, since: now.addingTimeInterval(-60 * 60),
                                                  until: nil, limit: 80)
        XCTAssertEqual(got.map(\.id), ["c", "b"])
        XCTAssertEqual(matched, 2)
    }

    func testTheRarestWordDecidesAndTheOrderSaidIsKept() {
        let now = Date()
        var all = (0..<30).map { note("n\($0)", Double(100 - $0), "the page loads the page", now: now) }
        all.append(note("price", 50.5, "Pricing should start at ten dollars on the page.", now: now))
        all.append(note("price2", 10, "And pricing for teams later.", now: now))
        let (got, matched) = ManagerNotes.select(all, query: "pricing page", since: nil, until: nil, limit: 2)
        XCTAssertEqual(got.map(\.id), ["price", "price2"], "the rare word outranks thirty common ones")
        XCTAssertEqual(matched, 32)
    }

    func testTheLedgerGivesOnlyTheDevelopersOwnLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = [
            #"{"n":1,"t":1790000000,"role":"user","kind":"talk","text":"The hero needs a darker overlay.","session":"s1"}"#,
            #"{"n":2,"t":1790000001,"role":"manager","kind":"spoken","text":"Sent.","session":"s1"}"#,
            #"{"n":3,"t":1790000002,"role":"agent","kind":"spoken","text":"Done.","speaker":"Site","session":"s1"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("ledger.jsonl"),
                                                         atomically: true, encoding: .utf8)
        let got = ManagerNotes.ledgerNotes(directory: dir)
        XCTAssertEqual(got.map(\.id), ["ledger:s1:1"])
        XCTAssertEqual(got.first?.source, "handsfree")
    }

    func testADayIsTheWholeCalendarDayInTheMacsZone() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let r = try XCTUnwrap(ManagerNotes.dayRange("2026-09-26", calendar: cal))
        let f = ISO8601DateFormatter()
        XCTAssertEqual(f.string(from: r.start), "2026-09-26T07:00:00Z", "midnight in Los Angeles")
        XCTAssertLessThan(r.end, try XCTUnwrap(f.date(from: "2026-09-27T07:00:00Z")))
        XCTAssertNil(ManagerNotes.dayRange("yesterday", calendar: cal))
    }

    func testAMissingDatabaseIsNoDictationsNotAFailure() {
        let got = ManagerNotes.dictationNotes(database: URL(fileURLWithPath: "/nonexistent/\(UUID()).sqlite"),
                                              since: nil, until: nil)
        XCTAssertTrue(got.isEmpty)
    }
}
