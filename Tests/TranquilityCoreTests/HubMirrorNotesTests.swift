import GRDB
import XCTest
@testable import TranquilityCore

/// Notes: the developer's own words, and nobody else's, reach the hub once
/// each and again when they change, from a ledger that rotates and a store
/// whose transcripts arrive late. Every test speaks to a fake hub, and every
/// word in here is invented.
final class HubMirrorNotesTests: XCTestCase {

    /// A hub that records notes and can be told to refuse them.
    final class NotesHub: HubMirror.Transport, @unchecked Sendable {
        var batches: [[[String: Any]]] = []
        var refuse = false
        var absent = false
        let lock = NSLock()
        func post(_ path: String, json: [String: Any]) async throws -> (status: Int, body: Data) {
            guard path == "api/ingest/notes" else { return (200, Data("{}".utf8)) }
            return lock.withLock {
                if absent { return (404, Data("Not Found".utf8)) }
                if refuse { return (500, Data("{\"error\":\"down\"}".utf8)) }
                batches.append((json["notes"] as? [[String: Any]]) ?? [])
                return (200, Data("{}".utf8))
            }
        }
        var notes: [[String: Any]] { lock.withLock { batches.flatMap { $0 } } }
        var keys: [String] { notes.compactMap { $0["source_key"] as? String } }
        func reset() { lock.withLock { batches = [] } }
    }

    private var tmp: URL!
    private var ledgerDir: URL { tmp.appendingPathComponent("ledger") }

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hub-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func mirror(_ hub: NotesHub, store: QueueStore? = nil, ledger: Bool = true) -> HubMirror {
        let m = HubMirror(transport: hub, agentsRoot: tmp.appendingPathComponent("agents").path,
                          stateURL: tmp.appendingPathComponent("state.json"), device: "test-mac",
                          store: store, artifactRoot: nil)
        m.liveSessions = { [:] }
        if ledger { m.ledgerDirectory = ledgerDir }
        return m
    }

    // MARK: Ledger lines

    private func line(_ n: Int, _ role: String, _ kind: String, _ text: String,
                      session: String = "hf-1", t: Double = 1_790_000_000, extra: String = "") -> String {
        let quoted = String(data: try! JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]),
                            encoding: .utf8)!.dropFirst().dropLast()
        return "{\"n\":\(n),\"t\":\(t + Double(n)),\"role\":\"\(role)\",\"kind\":\"\(kind)\",\"text\":\(quoted),\"session\":\"\(session)\"\(extra)}\n"
    }

    private func append(_ s: String, to name: String = "ledger.jsonl") throws {
        let url = ledgerDir.appendingPathComponent(name)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(s.utf8)); try h.close()
        } else {
            try Data(s.utf8).write(to: url)
        }
    }

    private func decode(_ s: String) -> ManagerLedger.Line {
        try! JSONDecoder().decode(ManagerLedger.Line.self, from: Data(s.utf8))
    }

    func testOnlyTheDevelopersLinesAreNotes() {
        let talk = HubMirror.notePayload(decode(line(7, "user", "talk", "the tide is out")))
        XCTAssertEqual(talk?["source_key"] as? String, "ledger:hf-1:7")
        XCTAssertEqual(talk?["source"] as? String, "handsfree")
        XCTAssertEqual(talk?["kind"] as? String, "talk")
        XCTAssertEqual(talk?["text"] as? String, "the tide is out")
        XCTAssertEqual(talk?["at"] as? String, "2026-09-21T14:13:27.000Z")
        XCTAssertNil(talk?["agent_session"])
        XCTAssertNotNil(HubMirror.notePayload(decode(line(8, "user", "command", "send it"))))
        XCTAssertNotNil(HubMirror.notePayload(decode(line(9, "user", "dictation", "dear crew"))))
        XCTAssertNil(HubMirror.notePayload(decode(line(10, "manager", "spoken", "on it"))))
        XCTAssertNil(HubMirror.notePayload(decode(line(11, "agent", "spoken", "done"))))
        XCTAssertNil(HubMirror.notePayload(decode(line(12, "user", "talk", "  \n "))), "nothing said is not a note")
    }

    func testALineAimedAtAnAgentCarriesItAndItsWordsAreUntouched() {
        let l = decode(line(3, "user", "dictation", "  two spaces in, and out  ",
                            extra: ",\"target\":\"sess-9\",\"targetName\":\"Ferry\""))
        let p = HubMirror.notePayload(l)
        XCTAssertEqual(p?["agent_session"] as? String, "sess-9")
        XCTAssertEqual(p?["agent_name"] as? String, "Ferry")
        XCTAssertEqual(p?["text"] as? String, "  two spaces in, and out  ", "copied exactly as stored")
    }

    func testTheLedgerIsReadFromWhereItStoppedAndAHalfWrittenLineWaits() throws {
        try append(line(1, "user", "talk", "one") + line(2, "manager", "spoken", "two"))
        let first = HubMirror.readLedger(directory: ledgerDir, after: nil)
        XCTAssertEqual(first.lines.map(\.n), [1, 2])
        let size = try FileManager.default.attributesOfItem(atPath: ledgerDir.appendingPathComponent("ledger.jsonl").path)[.size] as! Int64
        XCTAssertEqual(first.mark.offset, size)

        let third = line(3, "user", "talk", "three")
        try append(third + String(line(4, "user", "talk", "four").prefix(20)))
        let second = HubMirror.readLedger(directory: ledgerDir, after: first.mark)
        XCTAssertEqual(second.lines.map(\.n), [3], "the line still being written is not read")
        XCTAssertEqual(second.mark.offset, size + Int64(third.utf8.count))

        try append(String(line(4, "user", "talk", "four").dropFirst(20)))
        XCTAssertEqual(HubMirror.readLedger(directory: ledgerDir, after: second.mark).lines.map(\.n), [4])
        XCTAssertEqual(HubMirror.readLedger(directory: ledgerDir, after: HubMirror.readLedger(directory: ledgerDir, after: second.mark).mark).lines, [])
    }

    /// The ledger renames itself at 8 MB. The lines written after the last
    /// pass and before the rename went with the old file; they still arrive.
    func testARotatedLedgerIsReadAgainFromTheStartOfBothFiles() throws {
        try append(line(1, "user", "talk", "one"))
        let mark = HubMirror.readLedger(directory: ledgerDir, after: nil).mark
        try append(line(2, "user", "talk", "two, unsent when it rotated"))
        let fm = FileManager.default
        try fm.moveItem(at: ledgerDir.appendingPathComponent("ledger.jsonl"),
                        to: ledgerDir.appendingPathComponent("ledger.1.jsonl"))
        try append(line(3, "user", "talk", "three, in the new file, long enough to pass the old offset"))
        let read = HubMirror.readLedger(directory: ledgerDir, after: mark)
        XCTAssertEqual(read.lines.map(\.n), [1, 2, 3])
    }

    func testAReplacedLedgerShorterThanTheCursorStartsAgain() throws {
        try append(line(1, "user", "talk", "a long first line that sets a long offset"))
        let mark = HubMirror.readLedger(directory: ledgerDir, after: nil).mark
        try Data(line(1, "user", "talk", "new").utf8).write(to: ledgerDir.appendingPathComponent("ledger.jsonl"))
        XCTAssertEqual(HubMirror.readLedger(directory: ledgerDir, after: mark).lines.map(\.text), ["new"])
    }

    func testTheLedgerIsMirroredOnceAndOnlyTheDevelopersWords() async throws {
        try append(line(1, "user", "talk", "one") + line(2, "manager", "spoken", "two")
                   + line(3, "user", "command", "three"))
        let hub = NotesHub()
        let m = mirror(hub)
        let r = await m.run(docs: false, turns: true)
        XCTAssertEqual(hub.keys, ["ledger:hf-1:1", "ledger:hf-1:3"])
        XCTAssertEqual(r.notes, 2)
        XCTAssertTrue(r.note.hasSuffix("2 notes"), r.note)
        hub.reset()
        _ = await m.run(docs: false, turns: true)
        XCTAssertEqual(hub.keys, [], "a second pass over the same file sends nothing")

        // And a fresh mirror over the saved state agrees: the mark persisted.
        try append(line(4, "user", "talk", "four"))
        _ = await mirror(hub).run(docs: false, turns: true)
        XCTAssertEqual(hub.keys, ["ledger:hf-1:4"])
    }

    func testARefusedLedgerBatchLeavesTheMarkWhereItWas() async throws {
        try append(line(1, "user", "talk", "one"))
        let hub = NotesHub(); hub.refuse = true
        let m = mirror(hub)
        let r = await m.run(docs: false, turns: true)
        XCTAssertEqual(r.failed, 1)
        XCTAssertTrue(r.note.contains("notes: HTTP 500"), r.note)
        hub.refuse = false
        _ = await m.run(docs: false, turns: true)
        XCTAssertEqual(hub.keys, ["ledger:hf-1:1"], "the refused line is sent on the next pass")
    }

    /// The Mac can ship before the hub that takes notes. A hub without the
    /// route is not a failed sweep; the notes wait, and arrive once it has one.
    func testAHubWithoutNotesIsNotAFailedSweep() async throws {
        try append(line(1, "user", "talk", "one"))
        let hub = NotesHub(); hub.absent = true
        let m = mirror(hub)
        let r = await m.run(docs: false, turns: true)
        XCTAssertEqual(r.failed, 0)
        XCTAssertTrue(r.note.hasPrefix("ok:"), r.note)
        hub.absent = false
        _ = await m.run(docs: false, turns: true)
        XCTAssertEqual(hub.keys, ["ledger:hf-1:1"])
    }

    /// A state file written before notes existed still loads, cursors and
    /// all; otherwise the upgrade would resend every page this Mac has.
    func testAStateFileFromBeforeNotesStillLoads() throws {
        let old = #"{"files":{},"sent":["abc"],"turnCursor":42,"names":{},"assets":{},"linked":{}}"#
        let url = tmp.appendingPathComponent("state.json")
        try Data(old.utf8).write(to: url)
        let s = HubMirror.load(url)
        XCTAssertEqual(s.turnCursor, 42)
        XCTAssertEqual(s.sent, ["abc"])
        XCTAssertNil(s.notesLedger)
    }

    // MARK: Dictations

    private func store() throws -> QueueStore {
        try QueueStore(url: tmp.appendingPathComponent("q.sqlite"))
    }

    @discardableResult
    private func utter(_ s: QueueStore, _ id: String, _ text: String?, ms: Int64,
                       status: UtteranceStatus = .confirmed, to target: String? = "sess-a") throws -> Utterance {
        let u = Utterance(id: id, createdAtMs: ms, status: status, transcriptText: text, targetSessionId: target)
        try s.dbQueue.write { db in try u.insert(db) }
        return u
    }

    private func set(_ s: QueueStore, _ id: String, text: String? = nil, status: UtteranceStatus? = nil) throws {
        try s.dbQueue.write { db in
            if let text { try db.execute(sql: "UPDATE utterances SET transcriptText = ? WHERE id = ?", arguments: [text, id]) }
            if let status { try db.execute(sql: "UPDATE utterances SET status = ? WHERE id = ?", arguments: [status.rawValue, id]) }
        }
    }

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func testADictationIsANoteForItsAgent() {
        let d = HubMirror.Dictation(id: "u-1", createdAtMs: 1_790_000_000_123, status: "confirmed",
                                    text: "check the anchor chain", target: "sess-a")
        let p = HubMirror.notePayload(d, agentName: "Harbour")
        XCTAssertEqual(p["source_key"] as? String, "dictation:u-1")
        XCTAssertEqual(p["source"] as? String, "dictation")
        XCTAssertEqual(p["kind"] as? String, "confirmed")
        XCTAssertEqual(p["at"] as? String, "2026-09-21T14:13:20.123Z")
        XCTAssertEqual(p["agent_session"] as? String, "sess-a")
        XCTAssertEqual(p["agent_name"] as? String, "Harbour")
        let bare = HubMirror.notePayload(HubMirror.Dictation(id: "u-2", createdAtMs: 0, status: "ready",
                                                             text: "x", target: nil), agentName: nil)
        XCTAssertNil(bare["agent_session"]); XCTAssertNil(bare["agent_name"])
    }

    func testOnlyAChangedDictationIsSentAgain() {
        let d = HubMirror.Dictation(id: "u", createdAtMs: 5, status: "ready", text: "hello", target: "s")
        let sent = ["u": HubMirror.RecentMark(ms: 5, hash: HubMirror.dictationHash(d))]
        XCTAssertEqual(HubMirror.needsResend([d], recent: sent), [])
        let confirmed = HubMirror.Dictation(id: "u", createdAtMs: 5, status: "confirmed", text: "hello", target: "s")
        XCTAssertEqual(HubMirror.needsResend([confirmed], recent: sent), [confirmed])
        XCTAssertEqual(HubMirror.needsResend([d], recent: [:]), [d])
        XCTAssertEqual(HubMirror.pruned(sent, before: 6), [:])
        XCTAssertEqual(HubMirror.pruned(sent, before: 5), sent)
    }

    func testDictationsBackfillThenSendOnlyWhatIsNewOrChanged() async throws {
        let s = try store()
        let now = nowMs
        try utter(s, "old", "from last week", ms: now - 7 * 86_400_000)
        try utter(s, "a", "first", ms: now - 60_000)
        try utter(s, "pending", nil, ms: now - 50_000, status: .transcribing)
        try utter(s, "b", "second", ms: now - 40_000, status: .ready)
        try utter(s, "blank", "   ", ms: now - 30_000)
        let hub = NotesHub()
        let m = mirror(hub, store: s, ledger: false)
        _ = await m.run(docs: false, turns: true)
        XCTAssertEqual(hub.keys, ["dictation:old", "dictation:a", "dictation:b"], "every dictation with words, oldest first")

        hub.reset()
        _ = await m.run(docs: false, turns: true)
        XCTAssertEqual(hub.keys, [], "nothing changed, nothing sent")

        // Words that land after a later dictation moved the cursor past them,
        // a status that moves on, and a new dictation: each is sent once.
        try set(s, "pending", text: "late words", status: .ready)
        try set(s, "b", status: .confirmed)
        try utter(s, "c", "third", ms: now - 1_000)
        hub.reset()
        _ = await m.run(docs: false, turns: true)
        XCTAssertEqual(Set(hub.keys), ["dictation:c", "dictation:pending", "dictation:b"])
        XCTAssertEqual(hub.notes.first { $0["source_key"] as? String == "dictation:b" }?["kind"] as? String, "confirmed")

        hub.reset()
        _ = await m.run(docs: false, turns: true)
        XCTAssertEqual(hub.keys, [])
    }

    func testDictationsGoInBatchesOfAtMost500() async throws {
        let s = try store()
        let base = nowMs - 3 * 86_400_000
        try await s.dbQueue.write { db in
            for i in 0..<1_201 {
                try Utterance(id: String(format: "u%05d", i), createdAtMs: base + Int64(i), status: .confirmed,
                              transcriptText: "line \(i)", targetSessionId: nil).insert(db)
            }
        }
        let hub = NotesHub()
        let r = await mirror(hub, store: s, ledger: false).run(docs: false, turns: true)
        XCTAssertEqual(hub.batches.map(\.count), [500, 500, 201])
        XCTAssertEqual(r.notes, 1_201)
        XCTAssertEqual(Set(hub.keys).count, 1_201)
    }

    func testARefusedDictationBatchDoesNotMoveTheCursor() async throws {
        let s = try store()
        try utter(s, "a", "first", ms: nowMs - 1_000)
        let hub = NotesHub(); hub.refuse = true
        let m = mirror(hub, store: s, ledger: false)
        let r = await m.run(docs: false, turns: true)
        XCTAssertEqual(r.failed, 1)
        hub.refuse = false
        _ = await m.run(docs: false, turns: true)
        XCTAssertEqual(hub.keys, ["dictation:a"])
    }

    func testTwoDictationsInOneMillisecondAreBothSent() async throws {
        let s = try store()
        let ms = nowMs - 5_000
        try utter(s, "x-1", "one", ms: ms)
        let hub = NotesHub()
        let m = mirror(hub, store: s, ledger: false)
        _ = await m.run(docs: false, turns: true)
        try utter(s, "x-2", "two", ms: ms)
        hub.reset()
        _ = await m.run(docs: false, turns: true)
        XCTAssertEqual(hub.keys, ["dictation:x-2"], "the cursor is (time, id), not time alone")
    }
}
