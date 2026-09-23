import Foundation
import XCTest
@testable import TranquilityCore

/// The ledger's promises (hf-5, on hf-26's types): every `said` line, whole,
/// typed, numbered on this Mac, in order, surviving restarts and rotation;
/// nothing else gets in, and nothing is lost without being counted.
final class ManagerLedgerTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func said(_ role: String, _ kind: String, _ text: String, extra: [String: Any] = [:]) -> Data {
        var obj: [String: Any] = ["event": "said", "t": 1790186973.9, "n": 1, "role": role, "kind": kind, "text": text]
        obj.merge(extra) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testEverySaidLineIsKeptWholeTypedAndNumbered() {
        let ledger = ManagerLedger(directory: dir)
        let long = String(repeating: "the Back to School sends look stuck in draft ", count: 10)
        ledger.enqueue(line: said("user", "talk", long), session: "s1")
        ledger.enqueue(line: said("agent", "spoken", "Migration written.", extra: ["speaker": "Planning"]), session: "s1")
        ledger.flush()
        let lines = ledger.last(10)
        XCTAssertEqual(lines.map(\.n), [1, 2])
        XCTAssertEqual(lines[0].text, long, "the whole text, not 120 characters of it")
        XCTAssertEqual(lines[0].role, .user)
        XCTAssertEqual(lines[0].kind, .talk)
        XCTAssertEqual(lines[1].role, .agent)
        XCTAssertEqual(lines[1].speaker, "Planning")
        XCTAssertEqual(lines[1].session, "s1")
    }

    func testTheWebRTCSpacingDecodes() {
        let ledger = ManagerLedger(directory: dir)
        // Exactly the spacing the WebRTC path writes (manager-events.jsonl, 23 Sep 18:09).
        let spaced = #"{"event": "said", "t": 1790186973.949, "n": 1, "role": "user", "kind": "talk", "text": "Yes."}"#
        ledger.enqueue(line: Data(spaced.utf8), session: nil)
        ledger.flush()
        XCTAssertEqual(ledger.last(1).first?.text, "Yes.")
    }

    func testOtherEventsNeverEnterAndAreNotCountedAsLost() {
        let ledger = ManagerLedger(directory: dir)
        ledger.enqueue(line: Data(#"{"event":"listening","text":"I said \"said\" twice"}"#.utf8), session: nil)
        ledger.enqueue(line: Data(#"{"event":"jev","state":{}}"#.utf8), session: nil)
        ledger.enqueue(line: Data("not json said".utf8), session: nil)
        ledger.flush()
        XCTAssertTrue(ledger.last(10).isEmpty)
        XCTAssertEqual(ledger.unparsed, 0)
    }

    func testASaidLineThatDoesNotDecodeIsCountedAndReportedNeverGuessed() {
        let ledger = ManagerLedger(directory: dir)
        let reports = Reports()
        ledger.onUnparsed = { reports.add($0) }
        ledger.enqueue(line: said("robot", "talk", "who am I"), session: nil)           // unknown role
        ledger.enqueue(line: said("user", "mumble", "what kind is this"), session: nil)  // unknown kind
        ledger.enqueue(line: Data(#"{"event":"said","who":"you","status":"silent","text":"old shape"}"#.utf8), session: nil)
        ledger.flush()
        XCTAssertTrue(ledger.last(10).isEmpty, "nothing is stored under a guessed type")
        XCTAssertEqual(ledger.unparsed, 3)
        XCTAssertEqual(reports.count, 3)
    }

    func testNumberingCarriesOnAcrossARestart() {
        let a = ManagerLedger(directory: dir)
        a.record(said("user", "talk", "one"), session: "s1")
        a.record(said("user", "talk", "two"), session: "s1")
        let b = ManagerLedger(directory: dir)  // the app relaunched
        b.record(said("user", "talk", "three"), session: "s2")
        XCTAssertEqual(b.last(5).map(\.n), [1, 2, 3])
        XCTAssertEqual(b.lines(from: 2, to: 3).map(\.text), ["two", "three"])
    }

    func testRotationKeepsNumberingAndTheLastFileReadable() {
        let ledger = ManagerLedger(directory: dir, maxBytes: 400)
        for i in 1...12 { ledger.record(said("user", "talk", "line \(i) with some words in it"), session: nil) }
        let lines = ledger.last(100)
        XCTAssertEqual(lines.last?.n, 12)
        XCTAssertEqual(lines.map(\.n), Array((lines.first!.n)...12), "contiguous across the rotated file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ledger.1.jsonl").path))
        let reopened = ManagerLedger(directory: dir, maxBytes: 400)
        reopened.record(said("user", "talk", "after"), session: nil)
        XCTAssertEqual(reopened.last(1).first?.n, 13)
    }

    func testSinceLastActionStartsAfterTheManagerLastTypedIntoAnAgent() {
        let ledger = ManagerLedger(directory: dir)
        ledger.record(said("user", "dictation", "old dictation"), session: nil)
        ledger.record(said("manager", "action", "old dictation",
                           extra: ["target": "sid-mailchimp", "target_name": "Mailchimp"]), session: nil)
        ledger.record(said("user", "talk", "the cat knocked the monitor over"), session: nil)
        ledger.record(said("user", "command", "send that to the Mailchimp agent"), session: nil)
        let since = ledger.sinceLastAction()
        XCTAssertEqual(since.map(\.text), ["the cat knocked the monitor over", "send that to the Mailchimp agent"])
        XCTAssertTrue(since[1].isCommand, "the request to send is a command, never part of what is sent")
        XCTAssertFalse(since[0].isCommand)
        let action = ledger.last(4)[1]
        XCTAssertTrue(action.isAction)
        XCTAssertEqual(action.target, "sid-mailchimp")
        XCTAssertEqual(action.targetName, "Mailchimp")
        XCTAssertEqual(action.text, "old dictation", "the target is a field, not a prefix in the text")
    }

    func testTheLedgerToolServesTypedLinesByRangeLastAndSinceAction() async throws {
        let ledger = ManagerLedger(directory: dir)
        for t in ["a", "b", "c", "d"] { ledger.record(said("user", "talk", t), session: nil) }
        let host = ManagerToolHost(tools: ManagerTools.standard(tbase: "/usr/bin/false", ledger: ledger))
        func call(_ args: [String: Any]) async throws -> [[String: Any]] {
            let frame: [String: Any] = ["wire": "call", "id": "l", "tool": "ledger", "args": args]
            let reply = await host.handle(try JSONSerialization.data(withJSONObject: frame))
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(reply)) as? [String: Any])
            XCTAssertEqual(obj["ok"] as? Bool, true)
            return try XCTUnwrap(obj["data"] as? [[String: Any]])
        }
        let range = try await call(["from": 2, "to": 3])
        XCTAssertEqual(range.map { $0["text"] as? String }, ["b", "c"])
        XCTAssertEqual(range.first?["role"] as? String, "user")
        XCTAssertEqual(range.first?["kind"] as? String, "talk")
        let last = try await call(["last": 1])
        XCTAssertEqual(last.first?["n"] as? Int, 4)
        let since = try await call([:])
        XCTAssertEqual(since.count, 4, "no action yet: everything is since the last action")
    }

    /// Every `said` line the app has actually received, both transports,
    /// replayed: each one is either stored or counted as unparsed. None is
    /// lost silently. (Lines from before hf-26 have the old shape and are
    /// counted, which is the point: they are not guessed into types.)
    func testReplayOfTheRealEventLogLosesNoSaidLineSilently() throws {
        guard let path = ProcessInfo.processInfo.environment["TB_LEDGER_REPLAY"],
              let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("set TB_LEDGER_REPLAY to a manager-events.jsonl to replay")
        }
        let ledger = ManagerLedger(directory: dir)
        var said = 0
        for raw in data.split(separator: 0x0A) {
            let line = Data(raw)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["event"] as? String == "said" {
                said += 1
            }
            ledger.enqueue(line: line, session: nil)
        }
        ledger.flush()
        XCTAssertGreaterThan(said, 0)
        XCTAssertEqual(ledger.last(100_000).count + ledger.unparsed, said)
        print("replay: \(said) said lines, \(ledger.last(100_000).count) stored, \(ledger.unparsed) counted as unparsed")
    }

    func testNoLedgerMeansNoLedgerTool() {
        XCTAssertFalse(ManagerTools.standard(tbase: "/usr/bin/false").contains { $0.name == .ledger })
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}
