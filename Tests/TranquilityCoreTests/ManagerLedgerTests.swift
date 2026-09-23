import Foundation
import XCTest
@testable import TranquilityCore

/// The ledger's promises (hf-5): every `said` line, whole, numbered on this
/// Mac, in order, surviving restarts and rotation; nothing else gets in.
final class ManagerLedgerTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func said(_ who: String, _ text: String, _ status: String = "silent", spaced: Bool = false) -> Data {
        let obj: [String: Any] = ["event": "said", "t": 1790186973.9, "n": 1, "who": who, "status": status, "text": text]
        if spaced {
            // Exactly how the WebRTC path writes it (manager-events.jsonl, 23 Sep 18:09).
            let esc = text.replacingOccurrences(of: "\"", with: "\\\"")
            return Data(#"{"event": "said", "t": 1790186973.949, "n": 1, "who": "\#(who)", "status": "\#(status)", "text": "\#(esc)"}"#.utf8)
        }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testEverySaidLineIsKeptWholeAndNumbered() {
        let ledger = ManagerLedger(directory: dir)
        let long = String(repeating: "the Back to School sends look stuck in draft ", count: 10)
        ledger.enqueue(line: said("you", long), session: "s1")
        ledger.enqueue(line: said("Tranquility", "Inviting Planning to speak.", "spoken"), session: "s1")
        ledger.flush()
        let lines = ledger.last(10)
        XCTAssertEqual(lines.map(\.n), [1, 2])
        XCTAssertEqual(lines[0].text, long, "the whole text, not 120 characters of it")
        XCTAssertGreaterThan(lines[0].text.count, 120)
        XCTAssertEqual(lines[1].who, "Tranquility")
        XCTAssertEqual(lines[1].session, "s1")
    }

    func testTheWebRTCSpacingIsNotDropped() {
        let ledger = ManagerLedger(directory: dir)
        ledger.enqueue(line: said("you", "Yes.", spaced: true), session: nil)
        ledger.flush()
        XCTAssertEqual(ledger.last(1).first?.text, "Yes.", "the transport the app uses writes a space after the colon")
    }

    func testOtherEventsNeverEnter() {
        let ledger = ManagerLedger(directory: dir)
        ledger.enqueue(line: Data(#"{"event":"listening","text":"I said \"said\" twice"}"#.utf8), session: nil)
        ledger.enqueue(line: Data(#"{"event":"ready","build":"abc"}"#.utf8), session: nil)
        ledger.enqueue(line: Data("not json said".utf8), session: nil)
        ledger.flush()
        XCTAssertTrue(ledger.last(10).isEmpty)
    }

    func testNumberingCarriesOnAcrossARestart() {
        let a = ManagerLedger(directory: dir)
        a.append(said: said("you", "one"), session: "s1")
        a.append(said: said("you", "two"), session: "s1")
        let b = ManagerLedger(directory: dir)  // the app relaunched
        b.append(said: said("you", "three"), session: "s2")
        XCTAssertEqual(b.last(5).map(\.n), [1, 2, 3])
        XCTAssertEqual(b.lines(from: 2, to: 3).map(\.text), ["two", "three"])
    }

    func testRotationKeepsNumberingAndTheLastFileReadable() {
        let ledger = ManagerLedger(directory: dir, maxBytes: 400)
        for i in 1...12 { ledger.append(said: said("you", "line \(i) with some words in it"), session: nil) }
        let lines = ledger.last(100)
        XCTAssertEqual(lines.last?.n, 12)
        XCTAssertEqual(lines.map(\.n), Array((lines.first!.n)...12), "contiguous across the rotated file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ledger.1.jsonl").path))
        let reopened = ManagerLedger(directory: dir, maxBytes: 400)
        reopened.append(said: said("you", "after"), session: nil)
        XCTAssertEqual(reopened.last(1).first?.n, 13)
    }

    func testSinceLastActionStartsAfterTheManagerLastTypedIntoAnAgent() {
        let ledger = ManagerLedger(directory: dir)
        ledger.append(said: said("you", "old dictation"), session: nil)
        ledger.append(said: said("Tranquility", "(typing into Mailchimp) old dictation", "acted"), session: nil)
        ledger.append(said: said("you", "the cat knocked the monitor over"), session: nil)
        ledger.append(said: said("you", "send that to the Mailchimp agent", "acted"), session: nil)
        let since = ledger.sinceLastAction()
        XCTAssertEqual(since.map(\.text), ["the cat knocked the monitor over", "send that to the Mailchimp agent"])
        XCTAssertTrue(since[1].isCommand, "the request to send is a command, never part of what is sent")
        XCTAssertFalse(since[0].isCommand)
        XCTAssertTrue(ledger.last(4)[1].isAction)
    }

    func testTheLedgerToolServesLinesByRangeLastAndSinceAction() async throws {
        let ledger = ManagerLedger(directory: dir)
        for t in ["a", "b", "c", "d"] { ledger.append(said: said("you", t), session: nil) }
        let tools = ManagerTools.standard(tbase: "/usr/bin/false", ledger: ledger)
        let host = ManagerToolHost(tools: tools)
        func call(_ args: [String: Any]) async throws -> [[String: Any]] {
            let frame: [String: Any] = ["wire": "call", "id": "l", "tool": "ledger", "args": args]
            let reply = await host.handle(try JSONSerialization.data(withJSONObject: frame))
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(reply)) as? [String: Any])
            XCTAssertEqual(obj["ok"] as? Bool, true)
            return try XCTUnwrap(obj["data"] as? [[String: Any]])
        }
        let range = try await call(["from": 2, "to": 3])
        XCTAssertEqual(range.map { $0["text"] as? String }, ["b", "c"])
        let last = try await call(["last": 1])
        XCTAssertEqual(last.first?["n"] as? Int, 4)
        let since = try await call([:])
        XCTAssertEqual(since.count, 4, "no action yet: everything is since the last action")
    }

    /// Every `said` line the app has actually received, both transports,
    /// replayed through the ledger: none may be lost to formatting.
    func testReplayOfTheRealEventLogKeepsEverySaidLine() throws {
        guard let path = ProcessInfo.processInfo.environment["TB_LEDGER_REPLAY"],
              let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("set TB_LEDGER_REPLAY to a manager-events.jsonl to replay")
        }
        let ledger = ManagerLedger(directory: dir)
        var expected = 0
        for raw in data.split(separator: 0x0A) {
            let line = Data(raw)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               obj["event"] as? String == "said", (obj["text"] as? String)?.isEmpty == false { expected += 1 }
            ledger.enqueue(line: line, session: nil)
        }
        ledger.flush()
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(ledger.last(100_000).count, expected)
    }

    func testNoLedgerMeansNoLedgerTool() {
        XCTAssertFalse(ManagerTools.standard(tbase: "/usr/bin/false").contains { $0.name == "ledger" })
    }
}
