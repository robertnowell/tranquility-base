import XCTest
@testable import TranquilityCore

final class SessionKeywordIndexTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_500_000)

    func testSafariIsFoundByTheUsersWordsUnderItsRealTitle() async throws {
        let index = SessionKeywordIndex()
        try await index.replace(documents: [
            .init(id: "safari", title: "Safari compatibility and keyboard shortcuts", activity: now,
                  userText: "It loses focus after every keystroke.",
                  assistantText: "The panel guessed incorrectly whether the line was editing."),
            .init(id: "watchdog", title: "Audio watchdog", activity: now.addingTimeInterval(100),
                  assistantText: "The audio relay loses focus."),
            .init(id: "noise", title: "Session paused", activity: now.addingTimeInterval(200),
                  assistantText: "Doing nothing as requested.")])
        let hits = try await index.search("loses focus")
        XCTAssertEqual(hits.map(\.id), ["safari", "watchdog"])
        XCTAssertFalse(hits.contains { $0.id == "noise" })
        let title = try await index.search("keyboard short")
        XCTAssertEqual(title.first?.id, "safari")
    }

    func testEveryWordIsRequiredWithPrefixAndPluralSupport() async throws {
        let index = SessionKeywordIndex()
        try await index.replace(documents: [
            .init(id: "both", title: "Checkout attribution", activity: now,
                  reports: "Delete the abandoned cart after a purchase."),
            .init(id: "one", title: "An abandoned approach", activity: now)])
        let plural = try await index.search("abandoned carts")
        XCTAssertEqual(plural.map(\.id), ["both"])
        let prefix = try await index.search("abandoned ca")
        XCTAssertEqual(prefix.map(\.id), ["both"])
        let punctuation = try await index.search("\" OR ( - *)")
        XCTAssertTrue(punctuation.isEmpty, "query syntax is treated as literal words")
    }

    func testExactTitleThenUserPhraseThenOtherTextWithDeterministicTies() async throws {
        let index = SessionKeywordIndex()
        try await index.replace(documents: [
            .init(id: "a", title: "Older", activity: now, assistantText: "test artifacts"),
            .init(id: "b", title: "Newer", activity: now.addingTimeInterval(10), assistantText: "test artifacts"),
            .init(id: "user", title: "Green rows", activity: now, userText: "Those test artifacts remain."),
            .init(id: "title", title: "Test artifacts", activity: now.addingTimeInterval(-100))])
        let hits = try await index.search("test artifacts")
        XCTAssertEqual(hits.map(\.id), ["title", "user", "b", "a"])
        let again = try await index.search("TEST artifacts")
        XCTAssertEqual(hits, again)
    }

    func testBackgroundTextAndDiacriticsCanEarnResults() async throws {
        let index = SessionKeywordIndex()
        try await index.replace(documents: [
            .init(id: "abcd-1234", title: "Ordinary topic", metadata: "abcd-1234 /Projects/kopi",
                  activity: now, reports: "Café attribution lives in this report.")])
        let report = try await index.search("cafe attribut")
        XCTAssertEqual(report.first?.id, "abcd-1234")
        let identity = try await index.search("abcd-12")
        XCTAssertEqual(identity.first?.id, "abcd-1234")
        let path = try await index.search("Projects kopi")
        XCTAssertEqual(path.first?.id, "abcd-1234")
    }

    func testReplacementRemovesDeletedAndStaleResults() async throws {
        let index = SessionKeywordIndex()
        try await index.replace(documents: [.init(id: "old", title: "Oldword", activity: now)])
        try await index.replace(documents: [.init(id: "new", title: "Newword", activity: now)])
        let old = try await index.search("oldword")
        let new = try await index.search("newword")
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(new.map(\.id), ["new"])
    }

    func testCorpusUsesFullReadableHistoryAndReportTextAndRefreshesItsCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appendingPathComponent("session.jsonl")
        let iso = ISO8601DateFormatter().string(from: now)
        let line = #"{"type":"user","timestamp":"TIME","message":{"content":"earlier needle"}}"#.replacingOccurrences(of: "TIME", with: iso)
        let tools = #"{"type":"user","timestamp":"TIME","message":{"content":[{"type":"tool_result","content":"toolonly TOKEN"}]}}"#
            .replacingOccurrences(of: "TIME", with: iso).replacingOccurrences(of: "TOKEN", with: String(repeating: "x", count: 2_200_000))
        try (line + "\n" + tools + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        try "<html><head><title>unused</title><script>scriptsecret</script></head><body>reportneedle</body></html>"
            .write(to: folder.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
        try "hubnavigation".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let source = SessionKeywordIndex.Source(document: .init(id: "s", title: "Safari", activity: now),
                                                transcripts: [transcript], reportDirectories: [folder])
        let index = SessionKeywordIndex(cacheURL: folder.appendingPathComponent("search.sqlite"))
        let built = try await index.prepare(sources: [source], since: now.addingTimeInterval(-60))
        XCTAssertEqual(built.unreadableSources, 0)
        let earlier = try await index.search("earlier needle")
        let report = try await index.search("reportneedle")
        XCTAssertEqual(earlier.first?.id, "s")
        XCTAssertEqual(report.first?.id, "s")
        for needle in ["toolonly", "scriptsecret", "hubnavigation"] {
            let hits = try await index.search(needle)
            XCTAssertTrue(hits.isEmpty)
        }
        let reopened = SessionKeywordIndex(cacheURL: folder.appendingPathComponent("search.sqlite"))
        _ = try await reopened.prepare(sources: [source], since: now.addingTimeInterval(-30))
        let cached = try await reopened.search("earlier needle")
        XCTAssertEqual(cached.first?.id, "s")
        try line.replacingOccurrences(of: "earlier needle", with: "replacement words")
            .write(to: transcript, atomically: true, encoding: .utf8)
        _ = try await reopened.prepare(sources: [source], since: now.addingTimeInterval(-30))
        let stale = try await reopened.search("earlier needle")
        let replacement = try await reopened.search("replacement words")
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(replacement.first?.id, "s")
        _ = try await reopened.prepare(sources: [source], since: now.addingTimeInterval(1))
        let expired = try await reopened.search("replacement words")
        XCTAssertTrue(expired.isEmpty, "unchanged cached messages still obey the time window")
    }

    func testUnreadableTranscriptDoesNotHideReadableSourcesOrRetainItsOldText() async throws {
        let index = SessionKeywordIndex()
        try await index.replace(documents: [.init(id: "missing", title: "Gone", activity: now,
                                                  userText: "stale evidence")])
        let missing = URL(fileURLWithPath: "/missing-\(UUID().uuidString)/session.jsonl")
        let preparation = try await index.prepare(sources: [
            .init(document: .init(id: "missing", title: "Gone", activity: now), transcripts: [missing]),
            .init(document: .init(id: "readable", title: "Readable", activity: now,
                                  userText: "intact evidence"))], since: now.addingTimeInterval(-60))
        XCTAssertEqual(preparation.unreadableSources, 1)
        let stale = try await index.search("stale evidence")
        let readable = try await index.search("intact evidence")
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(readable.first?.id, "readable")
    }

    func testReadableParserExcludesScaffoldingAndKeepsBothSides() throws {
        func parse(_ row: [String: Any]) throws -> SessionSearchText.Message? {
            try SessionSearchText.message(in: JSONSerialization.data(withJSONObject: row))
        }
        let at = ISO8601DateFormatter().string(from: now)
        let user: [String: Any] = ["type": "user", "timestamp": at,
                                   "message": ["content": "[assistant]: recapword [user]: realword"]]
        XCTAssertEqual(try parse(user)?.text, "realword")
        var meta = user; meta["isMeta"] = true
        XCTAssertNil(try parse(meta))
        let assistant: [String: Any] = ["type": "assistant", "timestamp": at,
            "message": ["content": [["type": "thinking", "thinking": "hidden"],
                                     ["type": "tool_use", "input": "toolonly"],
                                     ["type": "text", "text": "actualreply"]]]]
        XCTAssertEqual(try parse(assistant)?.text, "actualreply")
        let codex: [String: Any] = ["type": "response_item", "timestamp": at,
            "payload": ["type": "message", "role": "user", "content": [
                ["type": "input_text", "text": "<environment_context>setup</environment_context>my request"]]]]
        XCTAssertEqual(try parse(codex)?.text, "my request")
        XCTAssertEqual(SessionSearchText.userWords("<task-notification>background</task-notification>"), "")
        XCTAssertEqual(SessionSearchText.userWords("<button>an example</button>"), "<button>an example</button>")
    }
}
