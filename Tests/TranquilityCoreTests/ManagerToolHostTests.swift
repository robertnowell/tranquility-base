import Foundation
import XCTest
@testable import TranquilityCore

/// Wire v1's promises, each checked against the host itself (hf-3).
final class ManagerToolHostTests: XCTestCase {
    /// The raw reply, which is Sendable and so can cross tasks.
    private static func raw(_ host: ManagerToolHost, _ tool: String, id: String = "c1",
                     deadline: Int? = nil, idem: String? = nil) async throws -> Data {
        var frame: [String: Any] = ["wire": "call", "id": id, "tool": tool, "args": [String: Any]()]
        if let deadline { frame["deadline_ms"] = deadline }
        if let idem { frame["idem"] = idem }
        let reply = await host.handle(try JSONSerialization.data(withJSONObject: frame))
        return try XCTUnwrap(reply)
    }

    private static func parse(_ d: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    private func call(_ host: ManagerToolHost, _ tool: String, id: String = "c1",
                      deadline: Int? = nil, idem: String? = nil) async throws -> [String: Any] {
        try Self.parse(try await Self.raw(host, tool, id: id, deadline: deadline, idem: idem))
    }

    private func code(_ r: [String: Any]) -> String? { (r["error"] as? [String: Any])?["code"] as? String }

    func testHelloListsTheOfferedToolsInOrder() async throws {
        let host = ManagerToolHost(tools: [
            ManagerTool(name: .agents, deadlineMs: 100, capBytes: 1000) { _ in [] },
            ManagerTool(name: .brief, version: 2, deadlineMs: 100, capBytes: 1000) { _ in [:] },
        ])
        let helloData = await host.hello(appVersion: "t")
        let hello = try Self.parse(helloData)
        XCTAssertEqual(hello["wire"] as? String, "hello")
        XCTAssertEqual(hello["protocol"] as? Int, 1)
        let tools = try XCTUnwrap(hello["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["agents", "brief"])
        XCTAssertEqual(tools[1]["version"] as? Int, 2)
    }

    func testAFrameOfUnknownOrWrongWayKindIsIgnoredNotActedOn() async throws {
        let runs = Counter()
        let host = ManagerToolHost(tools: [ManagerTool(name: .agents, deadlineMs: 100, capBytes: 1000) { _ in runs.bump(); return [] }])
        for kind in ["delete_everything", "result", "hello", "event"] {
            let frame: [String: Any] = ["wire": kind, "id": "z", "tool": "agents"]
            let reply = await host.handle(try JSONSerialization.data(withJSONObject: frame))
            XCTAssertNil(reply, "\(kind) is not something the bot may ask the Mac to do")
        }
        XCTAssertEqual(runs.value, 0)
    }

    /// The WebRTC data channel drops a message without `type`; a hello or a
    /// result sent bare never reached the bot (24 Sep).
    func testEveryFrameForTheDataChannelCarriesItsTypeAndKeepsItsContent() async throws {
        let host = ManagerToolHost(tools: [ManagerTool(name: .agents, deadlineMs: 1000, capBytes: 1000) { _ in ["a"] }])
        let helloData = await host.hello(appVersion: "t")
        let result = try await Self.raw(host, "agents")
        for frame in [helloData, result] {
            let obj = try Self.parse(ManagerDataChannel.stamped(frame))
            XCTAssertEqual(obj["type"] as? String, "tb")
            XCTAssertNotNil(obj["wire"], "the protocol fields survive the stamp")
        }
        XCTAssertEqual(try Self.parse(ManagerDataChannel.stamped(result))["data"] as? [String], ["a"])
    }

    func testAToolTheMacDoesNotOfferIsRefusedByName() async throws {
        let host = ManagerToolHost(tools: [])
        let r = try await call(host, "rm_rf")
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertEqual(code(r), "unknown_tool")
    }

    func testTheDeadlineKillsTheProcessAndSaysTimeout() async throws {
        let host = ManagerToolHost(tools: [
            ManagerTool(name: .agents, deadlineMs: 5000, capBytes: 1000) { _ in
                try await ManagerCommand.run("/bin/sleep", ["10"]).out
            },
        ])
        let t0 = Date()
        let r = try await call(host, "agents", deadline: 200)  // the call may ask for less than the tool's own
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0, "a 200 ms deadline must not wait for a 10 s process")
        XCTAssertEqual(code(r), "timeout")
        XCTAssertEqual((r["error"] as? [String: Any])?["retryable"] as? Bool, true)
    }

    func testACallCannotStretchTheToolsOwnDeadline() async throws {
        let host = ManagerToolHost(tools: [
            ManagerTool(name: .agents, deadlineMs: 200, capBytes: 1000) { _ in
                try await Task.sleep(nanoseconds: 3_000_000_000); return "late"
            },
        ])
        let t0 = Date()
        let r = try await call(host, "agents", deadline: 60_000)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0)
        XCTAssertEqual(code(r), "timeout")
    }

    func testAnEffectfulCallNeedsAnIdemKey() async throws {
        let host = ManagerToolHost(tools: [
            ManagerTool(name: .send, deadlineMs: 1000, capBytes: 1000, effectful: true) { _ in "typed" },
        ])
        let r = try await call(host, "send")
        XCTAssertEqual(code(r), "bad_args")
    }

    func testARepeatedIdemReturnsTheOutcomeAndNeverRunsTwice() async throws {
        let runs = Counter()
        let host = ManagerToolHost(tools: [
            ManagerTool(name: .send, deadlineMs: 1000, capBytes: 1000, effectful: true) { _ in
                runs.bump(); return ["outcome": "typed"]
            },
        ])
        let first = try await call(host, "send", id: "a", idem: "k1")
        let second = try await call(host, "send", id: "b", idem: "k1")
        XCTAssertEqual(runs.value, 1)
        XCTAssertEqual((first["data"] as? [String: Any])?["outcome"] as? String, "typed")
        XCTAssertEqual((second["data"] as? [String: Any])?["outcome"] as? String, "typed")
        XCTAssertEqual(second["repeat"] as? Bool, true)
    }

    /// The manager's `send` is the app's own Send (hf-12): the words and the
    /// agent reach it untouched, and what it came to is reported in the
    /// bot's words.
    func testTheStandardSendHandsTheWordsToTheAppsSendAndReportsHowItEnded() async throws {
        let seen = Box()
        let tools = ManagerTools.standard(tbase: "/nonexistent") { agent, text in
            seen.set("\(agent)|\(text)")
            return .dispatched(text: text, latencyMs: 5, sessionId: agent, pid: nil)
        }
        let host = ManagerToolHost(tools: tools)
        let frame: [String: Any] = ["wire": "call", "id": "s1", "tool": "send", "idem": "k-send",
                                    "args": ["agent": "abc", "text": "The sends are stuck in draft."]]
        let reply = await host.handle(try JSONSerialization.data(withJSONObject: frame))
        let r = try Self.parse(try XCTUnwrap(reply))
        XCTAssertEqual((r["data"] as? [String: Any])?["outcome"] as? String, "typed")
        XCTAssertEqual(seen.value, "abc|The sends are stuck in draft.")
    }

    func testASendWithNoWordsIsRefusedBeforeTheAppIsAsked() async throws {
        let seen = Box()
        let host = ManagerToolHost(tools: ManagerTools.standard(tbase: "/nonexistent") { _, _ in
            seen.set("asked"); return nil
        })
        let frame: [String: Any] = ["wire": "call", "id": "s2", "tool": "send", "idem": "k-empty",
                                    "args": ["agent": "abc", "text": "  "]]
        let reply = await host.handle(try JSONSerialization.data(withJSONObject: frame))
        let r = try Self.parse(try XCTUnwrap(reply))
        XCTAssertEqual(code(r), "bad_args")
        XCTAssertNil(seen.value)
    }

    /// Only a send the app saw land reads as typed; one that may have landed
    /// reads as ambiguous, so the bot never retries it into a double.
    func testASendOutcomeReadsAsTheBotNeedsIt() {
        typealias O = ManagerTools.SendOutcome
        XCTAssertEqual(O(.dispatched(text: "x", latencyMs: 1, sessionId: "s", pid: nil)), .typed)
        XCTAssertEqual(O(.queued(text: "x", sessionId: "s", pid: nil)), .queued)
        XCTAssertEqual(O(.dispatchFailed(.verificationTimedOut, utteranceId: "u")), .ambiguous)
        XCTAssertEqual(O(.duplicateSuppressed(utteranceId: "u")), .ambiguous)
        XCTAssertEqual(O(.dispatchFailed(.tabNotFound("t"), utteranceId: "u")), .notDispatched)
        XCTAssertEqual(O(.noTarget), .notDispatched)
        XCTAssertEqual(O(nil), .notDispatched)
    }

    func testARepeatWhileTheFirstIsStillRunningIsNotRunAgain() async throws {
        let runs = Counter()
        let host = ManagerToolHost(tools: [
            ManagerTool(name: .send, deadlineMs: 2000, capBytes: 1000, effectful: true) { _ in
                runs.bump(); try await Task.sleep(nanoseconds: 300_000_000); return "typed"
            },
        ])
        async let first = Self.raw(host, "send", id: "a", idem: "k2")
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = try await call(host, "send", id: "b", idem: "k2")
        _ = try await first
        XCTAssertEqual(code(second), "in_progress")
        XCTAssertEqual(runs.value, 1)
    }

    func testAnEffectThatTimedOutIsNeverRetriedByItsKey() async throws {
        let runs = Counter()
        let host = ManagerToolHost(tools: [
            ManagerTool(name: .send, deadlineMs: 100, capBytes: 1000, effectful: true) { _ in
                runs.bump(); try await Task.sleep(nanoseconds: 2_000_000_000); return "typed"
            },
        ])
        let first = try await call(host, "send", id: "a", idem: "k3")
        XCTAssertEqual(code(first), "timeout")
        XCTAssertEqual((first["error"] as? [String: Any])?["retryable"] as? Bool, false)
        let again = try await call(host, "send", id: "b", idem: "k3")
        XCTAssertEqual(code(again), "in_progress", "it may have happened: never run it a second time")
        XCTAssertEqual(runs.value, 1)
    }

    func testTheIdempotencyRecordSurvivesARestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idem-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = ManagerIdempotency(url: url)
        guard case .fresh = a.begin("k") else { return XCTFail("first begin is fresh") }
        a.finish("k", data: ["outcome": "typed"])
        let b = ManagerIdempotency(url: url)
        guard case .done = b.begin("k") else { return XCTFail("a new process must still know it was done") }
    }

    func testAnOversizedListIsCutFromTheEndItDoesNotKeepAndSaysSo() async throws {
        let host = ManagerToolHost(tools: [
            ManagerTool(name: .transcript, deadlineMs: 1000, capBytes: 2000, keep: .newest) { _ in
                (0..<500).map { "turn \($0)" }
            },
        ])
        let r = try await call(host, "transcript")
        XCTAssertEqual(r["truncated"] as? Bool, true)
        let list = try XCTUnwrap(r["data"] as? [String])
        XCTAssertEqual(list.last, "turn 499", "the newest end survives")
        XCTAssertFalse(list.contains("turn 0"))
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: list).count, 2000)
    }

    func testAResultUnderItsCapIsNotMarked() async throws {
        let host = ManagerToolHost(tools: [ManagerTool(name: .agents, deadlineMs: 1000, capBytes: 2000) { _ in ["a"] }])
        let r = try await call(host, "agents")
        XCTAssertNil(r["truncated"])
        XCTAssertEqual(r["ok"] as? Bool, true)
    }

    func testNoMoreThanFourReadsRunAtOnceAndTheRestWait() async throws {
        let host = ManagerToolHost(tools: [
            ManagerTool(name: .waiting, deadlineMs: 3000, capBytes: 1000) { _ in
                try await Task.sleep(nanoseconds: 200_000_000); return "ok"
            },
        ])
        try await withThrowingTaskGroup(of: Data.self) { group in
            for i in 0..<6 { group.addTask { try await Self.raw(host, "waiting", id: "r\(i)") } }
            for try await d in group { XCTAssertEqual(try Self.parse(d)["ok"] as? Bool, true) }
        }
        let peak = await host.peakReads
        XCTAssertEqual(peak, ManagerToolHost.maxReads)
    }

    func testCancelStopsACallInFlight() async throws {
        let host = ManagerToolHost(tools: [
            ManagerTool(name: .agents, deadlineMs: 5000, capBytes: 1000) { _ in
                try await ManagerCommand.run("/bin/sleep", ["10"]).out
            },
        ])
        async let r = Self.raw(host, "agents", id: "x")
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = await host.handle(try JSONSerialization.data(withJSONObject: ["wire": "cancel", "id": "x"]))
        let t0 = Date()
        let out = try Self.parse(try await r)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0)
        XCTAssertEqual(code(out), "cancelled")
    }

    func testTranscriptTailKeepsWholeTurnsNewestLast() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"first question"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"first answer"},{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"summary","summary":"not a turn"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"the last thing it said"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let tail = TranscriptTail.read(path: url.path, chars: 40)
        let turns = try XCTUnwrap(tail["turns"] as? [[String: String]])
        XCTAssertEqual(turns.last?["text"], "the last thing it said")
        XCTAssertEqual(turns.last?["who"], "assistant")
        XCTAssertFalse(turns.contains { $0["text"] == "first question" }, "40 characters keep only the newest turns")
        XCTAssertEqual(tail["total_turns"] as? Int, 3)
    }

    /// "What did I ask you for?" is at the start of a long session, far
    /// before any tail: a query finds it anywhere, in the order said (hf-6).
    func testATranscriptSearchFindsTheStartOfALongSessionInOrder() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var lines = [#"{"type":"user","message":{"content":"Build a landing page. Inspiration: technical manuals, clean type."}}"#]
        for i in 0..<200 { lines.append(#"{"type":"assistant","message":{"content":[{"type":"text","text":"working step \#(i)"}]}}"#) }
        lines.append(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Used the manuals inspiration for the hero."}]}}"#)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse((TranscriptTail.read(path: url.path, chars: 2000)["turns"] as? [[String: String]] ?? [])
            .contains { $0["text"]?.contains("Build a landing page") == true }, "the tail cannot reach it")
        let found = TranscriptTail.search(path: url.path, query: "landing page inspiration", chars: 2000)
        let turns = try XCTUnwrap(found["turns"] as? [[String: String]])
        XCTAssertEqual(turns.first?["text"], "Build a landing page. Inspiration: technical manuals, clean type.")
        XCTAssertEqual(turns.first?["turn"], "1")
        XCTAssertEqual(turns.count, 2, "the two turns that match, and none of the rest")
        XCTAssertEqual(turns.last?["who"], "assistant")
    }

    /// A Codex session read as empty: its turns are response_item messages.
    func testACodexTranscriptIsReadAsTurns() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"summarize the meeting"}]}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Eight decisions to review."}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let turns = try XCTUnwrap(TranscriptTail.read(path: url.path, chars: 1000)["turns"] as? [[String: String]])
        XCTAssertEqual(turns.map { $0["who"] ?? "" }, ["user", "assistant"])
        XCTAssertEqual(turns.last?["text"], "Eight decisions to review.")
    }

    func testAMissingTranscriptSaysSoRatherThanLookingEmpty() {
        let tail = TranscriptTail.read(path: "/nonexistent/\(UUID().uuidString).jsonl", chars: 100)
        XCTAssertEqual(tail["note"] as? String, "transcript file missing")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var v: String?
    func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return v }
}
