import XCTest
@testable import VoiceDispatchCore

final class QueueStoreTests: XCTestCase {
    var tmpDir: URL!
    var store: QueueStore!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Dedupe

    func testStopEventsDedupeOnPromptId() throws {
        let a = QueuedEvent(hookEvent: .stop, sessionId: "s1", promptId: "p1", lastAssistantMessage: "first")
        let b = QueuedEvent(hookEvent: .stop, sessionId: "s1", promptId: "p1", lastAssistantMessage: "duplicate")

        XCTAssertNotNil(try store.insert(event: a))
        XCTAssertNil(try store.insert(event: b), "a re-fired hook must not create a second row")
        XCTAssertEqual(try store.events().count, 1)
    }

    func testSameSessionDifferentPromptsBothLand() throws {
        XCTAssertNotNil(try store.insert(event: QueuedEvent(hookEvent: .stop, sessionId: "s1", promptId: "p1")))
        XCTAssertNotNil(try store.insert(event: QueuedEvent(hookEvent: .stop, sessionId: "s1", promptId: "p2")))
        XCTAssertEqual(try store.events().count, 2)
    }

    func testNotificationsAreNotDedupedByPromptId() throws {
        // Several permission prompts can occur within one turn; each is meaningful.
        XCTAssertNotNil(try store.insert(event: QueuedEvent(
            hookEvent: .notification, sessionId: "s1", promptId: "p1", notificationMatcher: "permission_prompt")))
        XCTAssertNotNil(try store.insert(event: QueuedEvent(
            hookEvent: .notification, sessionId: "s1", promptId: "p1", notificationMatcher: "idle_prompt")))
        XCTAssertEqual(try store.events().count, 2)
    }

    // MARK: - Retention safety (the property that must never regress)

    func testReapNeverTouchesAudioForRowsThatStillNeedIt() throws {
        let old = Int64(Date().addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970 * 1000)

        // One row per status, all far older than any retention window.
        var paths: [UtteranceStatus: String] = [:]
        for status in UtteranceStatus.allCases {
            let id = UUID().uuidString
            let path = tmpDir.appendingPathComponent("\(id).wav").path
            FileManager.default.createFile(atPath: path, contents: Data([0x01]))
            paths[status] = path
            try store.update(utterance: Utterance(
                id: id, createdAtMs: old, status: status, audioPath: path))
        }

        try store.reapAudio(olderThan: 1)

        for (status, path) in paths {
            let exists = FileManager.default.fileExists(atPath: path)
            if UtteranceStatus.reapable.contains(status) {
                XCTAssertFalse(exists, "\(status.rawValue) audio should have been reaped")
            } else {
                XCTAssertTrue(exists, "\(status.rawValue) audio must be retained regardless of age")
            }
        }
    }

    func testReapRespectsAgeForReapableRows() throws {
        let id = UUID().uuidString
        let path = tmpDir.appendingPathComponent("\(id).wav").path
        FileManager.default.createFile(atPath: path, contents: Data([0x01]))
        try store.update(utterance: Utterance(id: id, status: .confirmed, audioPath: path))

        try store.reapAudio(olderThan: 72 * 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "recent confirmed audio is inside the grace window")
    }

    // MARK: - Boot reconciliation

    func testMidDispatchRowsAreNeverAutoResent() throws {
        let dispatching = Utterance(status: .dispatching, transcriptText: "run the migration")
        let unconfirmed = Utterance(status: .dispatchedUnconfirmed, transcriptText: "ship it")
        try store.update(utterance: dispatching)
        try store.update(utterance: unconfirmed)

        let report = try store.reconcileOnBoot()

        XCTAssertEqual(Set(report.needsDeliveryCheck), Set([dispatching.id, unconfirmed.id]))
        // Critically: they are NOT put back into a state that would resend.
        let after = try store.utterances()
        for u in after where [dispatching.id, unconfirmed.id].contains(u.id) {
            XCTAssertTrue([.dispatching, .dispatchedUnconfirmed].contains(u.status),
                          "an ambiguous row must not be silently advanced or retried")
        }
    }

    func testRecordedRowWithAudioIsRequeued() throws {
        let id = UUID().uuidString
        let path = tmpDir.appendingPathComponent("\(id).wav").path
        FileManager.default.createFile(atPath: path, contents: Data([0x01]))
        try store.update(utterance: Utterance(id: id, status: .transcribing, audioPath: path))

        let report = try store.reconcileOnBoot()

        XCTAssertEqual(report.requeuedForTranscription, [id])
        XCTAssertEqual(try store.utterances().first?.status, .recorded)
    }

    func testRowWhoseAudioVanishedIsDiscardedAudibly() throws {
        let id = UUID().uuidString
        try store.update(utterance: Utterance(
            id: id, status: .recorded, audioPath: tmpDir.appendingPathComponent("gone.wav").path))

        let report = try store.reconcileOnBoot()

        XCTAssertEqual(report.missingAudio, [id])
        let row = try store.utterances().first
        XCTAssertEqual(row?.status, .discarded)
        XCTAssertNotNil(row?.discardedReason, "loss must be auditable, never silent")
    }

    // MARK: - Spool

    func testSpoolDrainInsertsDedupesAndSurvivesMalformedLines() throws {
        let spool = tmpDir.appendingPathComponent("spool.jsonl")
        let lines = [
            #"{"id":"e1","createdAtMs":1,"hookEvent":"Stop","sessionId":"s1","promptId":"p1","lastAssistantMessage":"done"}"#,
            #"{"id":"e2","createdAtMs":2,"hookEvent":"Stop","sessionId":"s1","promptId":"p1","lastAssistantMessage":"dupe"}"#,
            "{ this is not json",
            #"{"id":"e3","createdAtMs":3,"hookEvent":"Notification","sessionId":"s2","notificationMatcher":"permission_prompt"}"#,
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: spool, atomically: true, encoding: .utf8)

        let result = try SpoolDrainer(store: store, spoolURL: spool).drain()

        XCTAssertEqual(result.inserted, 2)
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(result.malformed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path), "spool is cleared after commit")
    }

    func testDrainIsIdempotentAcrossReplay() throws {
        let spool = tmpDir.appendingPathComponent("spool.jsonl")
        let line = #"{"id":"e1","createdAtMs":1,"hookEvent":"Stop","sessionId":"s1","promptId":"p1"}"#
        let drainer = SpoolDrainer(store: store, spoolURL: spool)

        try (line + "\n").write(to: spool, atomically: true, encoding: .utf8)
        XCTAssertEqual(try drainer.drain().inserted, 1)

        // Same line replayed (e.g. a crash before the spool was cleared).
        try (line + "\n").write(to: spool, atomically: true, encoding: .utf8)
        let second = try drainer.drain()
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.duplicates, 1)
        XCTAssertEqual(try store.events().count, 1)
    }

    func testDrainOnEmptySpoolIsHarmless() throws {
        let result = try SpoolDrainer(store: store, spoolURL: tmpDir.appendingPathComponent("nope.jsonl")).drain()
        XCTAssertEqual(result.inserted, 0)
    }
}
