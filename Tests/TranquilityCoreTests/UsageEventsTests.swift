import Foundation
import XCTest
@testable import TranquilityCore

/// The 24 Oct 2026 usage events: turn_completed's spool half, app_alive and
/// hub_opened. Each one on both sides.
final class UsageEventsTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-events-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func spoolLine(_ id: String, event: String = "Stop", harness: String? = nil,
                           transcript: String? = nil) -> String {
        var d: [String: Any] = ["id": id, "createdAtMs": 1_792_800_000_000, "hookEvent": event,
                                "sessionId": "489b4804-8d64-4a91-a63c-5e493141c772", "promptId": id,
                                "lastAssistantMessage": "Done."]
        if let harness { d["harness"] = harness }
        if let transcript { d["transcriptPath"] = transcript }
        return String(decoding: try! JSONSerialization.data(withJSONObject: d), as: UTF8.self) + "\n"
    }

    func testTheSpoolReportsEachNewlyFiledTurnWithItsHarnessOnce() throws {
        let store = try QueueStore(url: directory.appendingPathComponent("q.sqlite"))
        let url = directory.appendingPathComponent("spool.jsonl")
        let lines = spoolLine("t1", harness: "codex")
            + spoolLine("t2", transcript: "/Users/x/.claude/projects/p/s.jsonl")
            + spoolLine("t3", event: "UserPromptSubmit", harness: "claude")
            + spoolLine("t4", event: "SomethingNew", harness: "claude")
        try lines.write(to: url, atomically: true, encoding: .utf8)
        let result = try SpoolDrainer(store: store, spoolURL: url).drain()
        XCTAssertEqual(result.completed.map(\.harness), ["codex", "claude"],
                       "a Stop is a turn, from its field or its transcript's place; a prompt or an unknown kind is not")
        try (spoolLine("t1", harness: "codex")).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(try SpoolDrainer(store: store, spoolURL: url).drain().completed.isEmpty,
                      "a replayed line is a duplicate, not a second turn")
    }

    func testAppAliveCountsOnlyWhatThePersonDidAndSendsAFinishedDay() throws {
        let url = directory.appendingPathComponent("usage-day.json")
        let day = UsageDay(url: url)
        let monday = Date(timeIntervalSince1970: 1_792_800_000)
        day.observe("capture_started", [:], at: monday)
        day.observe("capture_started", [:], at: monday)
        day.observe("reply_outcome", ["outcome": .token("dispatched")], at: monday)
        day.observe("reply_outcome", ["outcome": .token("no_target")], at: monday)
        day.observe("agent_lamp_changed", [:], at: monday)       // the app, not the person
        day.observe("turn_arrived", [:], at: monday)             // an agent, not the person
        var sent: [(String, [String: TrackValue])] = []
        day.flush(now: monday) { sent.append(($0, $1)) }
        XCTAssertTrue(sent.isEmpty, "the day is not finished")

        // A relaunch the same day keeps the count.
        let again = UsageDay(url: url)
        again.flush(now: monday.addingTimeInterval(86_400 * 1.2)) { sent.append(($0, $1)) }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0, "app_alive")
        let p = sent[0].1
        XCTAssertEqual(p["captures"], .int(2))
        XCTAssertEqual(p["replies_sent"], .int(1))
        XCTAssertEqual(p["actions"], .int(3))
        XCTAssertEqual(p["hub_opened"], .int(0), "every count is present, zero included")
        XCTAssertEqual(Set(p.keys), Set(UsageDay.counts + ["day", "actions"]))
        XCTAssertTrue(p.values.allSatisfy(\.isAdmissible))
        sent = []
        again.flush(now: monday.addingTimeInterval(86_400 * 1.2 + 60)) { sent.append(($0, $1)) }
        XCTAssertTrue(sent.isEmpty, "a day is sent once")
    }

    func testAnActionAfterMidnightBeforeTheDrainStillLandsInItsOwnDay() {
        let day = UsageDay(url: directory.appendingPathComponent("u.json"))
        let monday = Date(timeIntervalSince1970: 1_792_800_000)
        day.observe("typed_reply", [:], at: monday)
        day.observe("typed_reply", [:], at: monday.addingTimeInterval(86_400))
        var sent: [[String: TrackValue]] = []
        day.flush(now: monday.addingTimeInterval(86_400)) { sent.append($1) }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]["typed_replies"], .int(1), "Monday's one, not Tuesday's")
    }

    func testHubOpenedNamesThePageTypeAndNothingElse() {
        func t(_ s: String) -> String { HubWindow.pageType(URL(string: s)) }
        XCTAssertEqual(t("https://hq.example/open?session=abc&slug=uvape-report"), "report")
        XCTAssertEqual(t("https://hq.example/open?session=abc"), "agent")
        XCTAssertEqual(t("https://hq.example/d/5c76f429"), "document")
        XCTAssertEqual(t("https://hq.example/a/123"), "agent")
        XCTAssertEqual(t("https://hq.example/"), "home")
        XCTAssertEqual(t("https://hq.example/connect"), "connect")
        XCTAssertEqual(t("https://hq.example/settings/billing"), "other")
        XCTAssertEqual(HubWindow.pageType(nil), "home")
    }
}
