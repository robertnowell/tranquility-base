import XCTest
@testable import TranquilityCore

final class SessionKeywordIndexTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_500_000)
    private typealias Source = SessionKeywordIndex.Source

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func line(_ role: String, _ text: String, at: Date) -> String {
        let row: [String: Any] = ["type": role, "timestamp": ISO8601DateFormatter().string(from: at),
                                  "message": ["content": text]]
        return String(data: try! JSONSerialization.data(withJSONObject: row), encoding: .utf8)! + "\n"
    }

    /// A session whose conversation is written to a real log file.
    private func session(_ id: String, title: String, in folder: URL, activity: Date? = nil,
                         _ lines: [(String, String, Date)], metadata: String = "",
                         summary: String? = "") throws -> Source {
        let log = folder.appendingPathComponent("\(id).jsonl")
        try lines.map { line($0.0, $0.1, at: $0.2) }.joined()
            .write(to: log, atomically: true, encoding: .utf8)
        return Source(id: id, title: title, metadata: metadata, summary: summary,
                      activity: activity ?? lines.map(\.2).max() ?? now, transcripts: [log])
    }

    func testAResultQuotesTheMatchingMessageWithItsSpeakerAndTime() async throws {
        let dir = try folder()
        let index = SessionKeywordIndex()
        let said = now.addingTimeInterval(-500)
        try await index.refresh(sources: [
            try session("safari", title: "Safari compatibility and keyboard shortcuts", in: dir, [
                ("user", "It loses focus after every keystroke.", said),
                ("assistant", "The panel guessed incorrectly whether the line was editing.", now)]),
            try session("noise", title: "Session paused", in: dir, [
                ("assistant", "Doing nothing as requested.", now)])])
        let hits = try index.search("loses focus", order: .recent)
        XCTAssertEqual(hits.map(\.id), ["safari"])
        XCTAssertEqual(hits[0].role, .user)
        XCTAssertEqual(hits[0].at, said)
        XCTAssertEqual(hits[0].count, 1)
        let open = String(SessionKeywordIndex.Match.open), close = String(SessionKeywordIndex.Match.close)
        XCTAssertTrue(hits[0].excerpt.contains("\(open)loses\(close) \(open)focus\(close)"),
                      "matched words are marked: \(hits[0].excerpt.debugDescription)")
        XCTAssertEqual(hits[0].plainExcerpt, "It loses focus after every keystroke.")
    }

    func testANameOnlyMatchHasNoQuoteAndNeverShowsIdentityText() async throws {
        let dir = try folder()
        let index = SessionKeywordIndex()
        try await index.refresh(sources: [
            try session("abcd-1234", title: "Keyboard shortcuts", in: dir,
                        [("assistant", "Nothing relevant here.", now)],
                        metadata: "abcd-1234 /Projects/kopi/hero-worktree")])
        for query in ["keyboard short", "abcd-12", "hero worktree"] {
            let hits = try index.search(query)
            XCTAssertEqual(hits.map(\.id), ["abcd-1234"], query)
            XCTAssertEqual(hits[0].excerpt, "", "identity text is never quoted (\(query))")
            XCTAssertEqual(hits[0].count, 0)
        }
    }

    func testEveryWordIsRequiredWithPrefixAndPluralSupport() async throws {
        let dir = try folder()
        let index = SessionKeywordIndex()
        try await index.refresh(sources: [
            try session("both", title: "Checkout attribution", in: dir,
                        [("assistant", "Delete the abandoned cart after a purchase.", now)]),
            try session("one", title: "An abandoned approach", in: dir, [])])
        XCTAssertEqual(try index.search("abandoned carts").map(\.id), ["both"])
        XCTAssertEqual(try index.search("abandoned ca").map(\.id), ["both"])
        XCTAssertTrue(try index.search("\" OR ( - *)").isEmpty, "query syntax is treated as literal words")
    }

    func testRelevantRanksExactNameThenYourPhraseThenTheAgentsAndRecentRanksByTime() async throws {
        let dir = try folder()
        let index = SessionKeywordIndex()
        try await index.refresh(sources: [
            try session("a", title: "Older", in: dir, [("assistant", "test artifacts", now)]),
            try session("b", title: "Newer", in: dir,
                        [("assistant", "test artifacts", now.addingTimeInterval(10))]),
            try session("user", title: "Green rows", in: dir,
                        [("user", "Those test artifacts remain.", now.addingTimeInterval(-50))]),
            try session("title", title: "Test artifacts", in: dir, activity: now.addingTimeInterval(-100), [])])
        let relevant = try index.search("test artifacts", order: .relevant)
        XCTAssertEqual(relevant.map(\.id), ["title", "user", "b", "a"])
        XCTAssertEqual(relevant, try index.search("TEST artifacts", order: .relevant))
        let recent = try index.search("test artifacts", order: .recent)
        XCTAssertEqual(recent.map(\.id), ["b", "a", "user", "title"])
    }

    func testRecentShowsTheNewestPassageAndCountsTheRest() async throws {
        let dir = try folder()
        let index = SessionKeywordIndex()
        try await index.refresh(sources: [
            try session("s", title: "Watermark work", in: dir, [
                ("user", "The watermark is on every timer.", now.addingTimeInterval(-300)),
                ("assistant", "I removed the watermark from six brands.", now.addingTimeInterval(-200)),
                ("assistant", "The watermark SQL still needs one run.", now.addingTimeInterval(-100))])])
        let recent = try index.search("watermark", order: .recent)
        XCTAssertEqual(recent.first?.count, 3)
        XCTAssertEqual(recent.first?.plainExcerpt, "The watermark SQL still needs one run.")
        XCTAssertEqual(recent.first?.at, now.addingTimeInterval(-100))
        let relevant = try index.search("watermark", order: .relevant)
        XCTAssertEqual(relevant.first?.role, .user, "your own words outrank the agent's")
    }

    func testAGrownLogIsReadFromWhereTheLastReadStopped() async throws {
        let dir = try folder()
        let index = SessionKeywordIndex(cacheURL: dir.appendingPathComponent("index.sqlite"))
        let first = try session("s", title: "Growing", in: dir, [("user", "earlier needle", now)])
        let built = try await index.refresh(sources: [first])
        XCTAssertEqual(built.filesRead, 1)
        XCTAssertEqual(built.messagesAdded, 1)
        let idle = try await index.refresh(sources: [first])
        XCTAssertEqual(idle.filesRead, 0, "an unchanged log costs one stat")

        // Append a whole line and a half-written one.
        let log = first.transcripts[0]
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line("assistant", "later needle", at: now.addingTimeInterval(5)).utf8))
        let partial = line("user", "unfinished needle", at: now.addingTimeInterval(9))
        try handle.write(contentsOf: Data(partial.dropLast(12).utf8))
        try handle.close()
        let grown = try await index.refresh(sources: [first])
        XCTAssertEqual(grown.messagesAdded, 1, "only the new complete line was read")
        XCTAssertEqual(try index.search("needle").first?.count, 2)
        XCTAssertTrue(try index.search("unfinished").isEmpty)

        // The harness finishes the line: it is read whole, once.
        let finish = try FileHandle(forWritingTo: log)
        try finish.seekToEnd()
        try finish.write(contentsOf: Data(partial.suffix(12).utf8))
        try finish.close()
        let finished = try await index.refresh(sources: [first])
        XCTAssertEqual(finished.messagesAdded, 1)
        XCTAssertEqual(try index.search("needle").first?.count, 3)

        // A second process sees the same index without building anything.
        let reopened = SessionKeywordIndex(cacheURL: dir.appendingPathComponent("index.sqlite"))
        XCTAssertEqual(try reopened.search("earlier needle").map(\.id), ["s"])
        let untouched = try await reopened.refresh(sources: [first])
        XCTAssertEqual(untouched.filesRead, 0)
    }

    func testAReplacedLogIsReadAgainAndAMissingOneKeepsNoText() async throws {
        let dir = try folder()
        let index = SessionKeywordIndex()
        var source = try session("s", title: "Rewritten", in: dir, [("user", "stale evidence", now)])
        try await index.refresh(sources: [source])
        source = try session("s", title: "Rewritten", in: dir, [("user", "fresh", now)])
        try await index.refresh(sources: [source])
        XCTAssertTrue(try index.search("stale").isEmpty)
        XCTAssertEqual(try index.search("fresh").map(\.id), ["s"])

        try FileManager.default.removeItem(at: source.transcripts[0])
        let other = try session("readable", title: "Readable", in: dir, [("user", "intact evidence", now)])
        let refresh = try await index.refresh(sources: [source, other])
        XCTAssertEqual(refresh.unreadableSources, 1)
        XCTAssertTrue(try index.search("fresh").isEmpty)
        XCTAssertEqual(try index.search("intact evidence").map(\.id), ["readable"])
    }

    func testASessionThatLeavesIsForgottenButAnEmptyScanErasesNothing() async throws {
        let dir = try folder()
        let index = SessionKeywordIndex()
        let old = try session("old", title: "Oldword", in: dir, [("user", "oldtext", now)])
        let new = try session("new", title: "Newword", in: dir, [("user", "newtext", now)])
        try await index.refresh(sources: [old, new])
        try await index.refresh(sources: [])
        XCTAssertEqual(try index.search("oldtext").map(\.id), ["old"], "a failed scan is not an empty archive")
        try await index.refresh(sources: [new])
        XCTAssertTrue(try index.search("oldtext").isEmpty)
        XCTAssertTrue(try index.search("oldword").isEmpty)
        XCTAssertEqual(try index.search("newtext").map(\.id), ["new"])
    }

    func testReportsAndSummariesAreQuotedAndToolOutputIsNot() async throws {
        let dir = try folder()
        let iso = ISO8601DateFormatter().string(from: now)
        let tools = #"{"type":"user","timestamp":"TIME","message":{"content":[{"type":"tool_result","content":"toolonly TOKEN"}]}}"#
            .replacingOccurrences(of: "TIME", with: iso)
            .replacingOccurrences(of: "TOKEN", with: String(repeating: "x", count: 2_200_000))
        let log = dir.appendingPathComponent("s.jsonl")
        try (line("user", "earlier needle", at: now) + tools + "\n").write(to: log, atomically: true, encoding: .utf8)
        let reports = dir.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reports.appendingPathComponent("2026-brief"),
                                                withIntermediateDirectories: true)
        try "<html><head><title>unused</title><script>scriptsecret</script></head><body>reportneedle</body></html>"
            .write(to: reports.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
        try "hubnavigation".write(to: reports.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "<html><body>briefneedle</body></html>".write(
            to: reports.appendingPathComponent("2026-brief/index.html"), atomically: true, encoding: .utf8)
        let index = SessionKeywordIndex()
        let source = Source(id: "s", title: "Safari", summary: "summaryneedle in a stored brief",
                            activity: now, transcripts: [log], reportDirectories: [reports])
        let built = try await index.refresh(sources: [source])
        XCTAssertEqual(built.unreadableSources, 0)
        XCTAssertEqual(try index.search("earlier needle").first?.role, .user)
        XCTAssertEqual(try index.search("reportneedle").first?.role, .report)
        XCTAssertEqual(try index.search("briefneedle").first?.role, .report,
                       "a report in its own folder is index.html too, and it is a report")
        XCTAssertEqual(try index.search("summaryneedle").first?.role, .summary)
        for needle in ["toolonly", "scriptsecret", "hubnavigation"] {
            XCTAssertTrue(try index.search(needle).isEmpty, needle)
        }
        // A nil summary keeps what is stored, and an empty one removes it.
        try await index.refresh(sources: [Source(id: "s", title: "Safari", summary: nil, activity: now,
                                                 transcripts: [log], reportDirectories: [reports])])
        XCTAssertEqual(try index.search("summaryneedle").map(\.id), ["s"])
        try await index.refresh(sources: [Source(id: "s", title: "Safari", summary: "", activity: now,
                                                 transcripts: [log], reportDirectories: [reports])])
        XCTAssertTrue(try index.search("summaryneedle").isEmpty)
    }

    func testSomethingSaidStandsForAnAgentBeforeAPageAboutIt() async throws {
        let dir = try folder()
        let reports = dir.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try "<html><body>A page that mentions the watermark fix.</body></html>"
            .write(to: reports.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        let said = now.addingTimeInterval(-86_400)
        var source = try session("s", title: "Timers", in: dir, [("user", "Remove the watermark please.", said)])
        source = Source(id: "s", title: "Timers", activity: now, transcripts: source.transcripts,
                        reportDirectories: [reports])
        let index = SessionKeywordIndex()
        try await index.refresh(sources: [source])
        for order in SessionKeywordIndex.Order.allCases {
            let hit = try XCTUnwrap(try index.search("watermark", order: order).first)
            XCTAssertEqual(hit.role, .user, "\(order)")
            XCTAssertEqual(hit.at, said, "dated by what was said, not by the page's file clock")
            XCTAssertEqual(hit.count, 2)
        }
        XCTAssertEqual(try index.search("mentions", order: .recent).first?.role, .report,
                       "a page still answers when nothing said does")
    }

    func testOnlyTheFirstPageIsGivenItsPassages() async throws {
        let dir = try folder()
        let index = SessionKeywordIndex()
        try await index.refresh(sources: try (0..<5).map {
            try session("s\($0)", title: "Agent \($0)", in: dir,
                        [("user", "pageword \($0)", now.addingTimeInterval(Double($0)))])
        })
        let page = try index.search("pageword", order: .recent, excerpts: 2)
        XCTAssertEqual(page.map(\.id), ["s4", "s3", "s2", "s1", "s0"])
        XCTAssertEqual(page.map { $0.excerpt.isEmpty }, [false, false, true, true, true])
        XCTAssertEqual(page.map(\.count), [1, 1, 1, 1, 1], "every result is still counted")
    }

    func testALineIsParsedOnlyWhenItCanHoldAMessage() throws {
        let at = ISO8601DateFormatter().string(from: now)
        func holds(_ json: String) -> Bool { SessionSearchText.mayHoldMessage(Data(json.utf8)) }
        XCTAssertTrue(holds(#"{"type":"user","timestamp":"\#(at)","message":{"content":"hello"}}"#))
        XCTAssertTrue(holds(#"{"timestamp":"\#(at)","type":"response_item","payload":{}}"#))
        XCTAssertFalse(holds(#"{"type":"user","toolUseResult":{"stdout":"x"},"message":{}}"#))
        XCTAssertFalse(holds(#"{"type":"attachment","content":"big"}"#))
        // A person who TYPES those words is still read: in the file their
        // quotes are escaped, so the bytes differ from a real key.
        let typed: [String: Any] = ["type": "user", "timestamp": at,
            "message": ["content": #"what does "toolUseResult": mean, or "type":"attachment"?"#]]
        let line = try JSONSerialization.data(withJSONObject: typed)
        XCTAssertTrue(SessionSearchText.mayHoldMessage(line))
        XCTAssertNotNil(SessionSearchText.message(in: line))
    }

    func testTheDirectTimestampReaderAgreesWithTheFormatter() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let seconds = Double(Int.random(in: 0..<2_000_000_000, using: &generator))
            let millis = Double(Int.random(in: 0..<1_000, using: &generator)) / 1_000
            let whole = plain.string(from: Date(timeIntervalSince1970: seconds))
            XCTAssertEqual(RolloutClock.utc(whole), plain.date(from: whole), whole)
            let split = fractional.string(from: Date(timeIntervalSince1970: seconds + millis))
            let fast = RolloutClock.utc(split), slow = fractional.date(from: split)
            XCTAssertNotNil(fast, split)
            XCTAssertEqual(fast?.timeIntervalSince1970 ?? 0, slow?.timeIntervalSince1970 ?? -1,
                           accuracy: 0.000_5, split)
        }
        for odd in ["2026-02-29T00:00:00Z", "2024-02-29T23:59:59.5Z", "1999-12-31T23:59:59.123456Z"] {
            let slow = fractional.date(from: odd) ?? plain.date(from: odd)
            if let fast = RolloutClock.utc(odd), let slow {
                XCTAssertEqual(fast.timeIntervalSince1970, slow.timeIntervalSince1970, accuracy: 0.000_5, odd)
            }
        }
        for other in ["", "2026-11-15", "2026-11-15T22:28:27+01:00", "2026-11-15 22:28:27Z", "20261115T222827Z",
                      "2026-13-01T00:00:00Z", "2026-11-15T22:28:27.Z"] {
            XCTAssertNil(RolloutClock.utc(other), "\(other) is left to the formatter")
        }
        XCTAssertNotNil(RolloutClock.date("2026-11-15T22:28:27+01:00"), "the formatter still reads an offset")
    }

    func testOneAgentOfSeveralSessionsIsOneResult() {
        typealias Match = SessionKeywordIndex.Match
        let early = Date(timeIntervalSince1970: 100), late = Date(timeIntervalSince1970: 200)
        let matches = [
            Match(id: "continued", role: .assistant, at: late, excerpt: "late words", count: 2, tier: 3, score: -1),
            Match(id: "other", role: .user, at: Date(timeIntervalSince1970: 150), excerpt: "other", count: 1, tier: 2, score: -2),
            Match(id: "origin", role: .user, at: early, excerpt: "early words", count: 3, tier: 2, score: -3),
            Match(id: "stranger", role: .user, at: late, excerpt: "no row", count: 1, tier: 2, score: -9)]
        let owner: (String) -> String? = { ["continued": "agent", "origin": "agent", "other": "other"][$0] }
        let recent = SessionKeywordIndex.merge(matches, order: .recent, owner: owner)
        XCTAssertEqual(recent.map(\.id), ["agent", "other"])
        XCTAssertEqual(recent[0].count, 5)
        XCTAssertEqual(recent[0].excerpt, "late words")
        XCTAssertEqual(recent[0].at, late)
        let relevant = SessionKeywordIndex.merge(matches, order: .relevant, owner: owner)
        XCTAssertEqual(relevant.map(\.id), ["agent", "other"], "tier 2 and the better score both come from origin")
        XCTAssertEqual(relevant[0].tier, 2)
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
