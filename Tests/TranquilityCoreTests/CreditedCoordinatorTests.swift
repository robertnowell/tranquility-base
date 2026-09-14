import Foundation
import GRDB
import XCTest
@testable import TranquilityCore

final class CreditedCoordinatorTests: XCTestCase {
    let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let origin = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("credited-coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func store(_ name: String = "queue") throws -> QueueStore {
        try QueueStore(url: directory.appendingPathComponent("\(name).sqlite"))
    }
    func event(_ id: String = "original-event") -> QueuedEvent {
        QueuedEvent(id: id, createdAtMs: Int64(Date().timeIntervalSince1970 * 1000), hookEvent: .stop,
                    sessionId: "sess-1", promptId: id, lastAssistantMessage: "The export is ready. All tests passed.")
    }
    var source: GatewaySource { .localHook(event(), originId: origin) }
    func insert(_ store: QueueStore, event: QueuedEvent? = nil, source: GatewaySource? = nil) throws -> WaitingSession {
        let event = event ?? self.event()
        try store.insert(event: event, summarySource: source ?? .localHook(event, originId: origin))
        return try XCTUnwrap(store.waitingSessions().first)
    }
    func result(source: GatewaySource? = nil) -> GatewayOperation {
        let id = (source ?? self.source).operationId(accountId: account)
        return GatewayOperation(version: "1", accountId: account.uuidString.lowercased(), operationId: id,
            state: .succeeded, brief: SessionBrief(topic: "Export", happened: "All tests passed.", recap: "The export is ready."),
            receipt: GatewayReceipt(id: "22222222-2222-4222-8222-222222222222", accountId: account.uuidString.lowercased(),
                operationId: id, currency: "USD", chargedMicros: "20000", pricebookVersion: "fixture-summary-v1",
                settledAt: "2026-09-13T19:00:00.000Z", balanceAfter: GatewayBalance(availableMicros: "9980000", reservedMicros: "0", ledgerSequence: "3")), error: nil)
    }
    func coordinator(_ store: QueueStore, transport: any GatewayTransport,
                     outboxName: String = "outbox", speechFails: Bool = false) throws -> Coordinator {
        let client = ManagedSummaryClient(accountId: account, transport: transport,
            outbox: try ManagedSummaryOutbox(url: directory.appendingPathComponent("\(outboxName).sqlite")))
        let speech = SilentSpeech(fails: speechFails)
        return Coordinator(store: store, summarizer: SummarizerChain(managed: ManagedSummaryProvider(client: client)),
            localSummaryOriginId: origin, speech: SpeechChain(preferred: speech, fallback: speech),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
            enrolment: EnrolmentRegistry(url: directory.appendingPathComponent("enrolled.json")), agents: Agents(),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))
    }
    struct Agents: ClaudeAgentsReading { func sessions() -> [LiveSession]? { nil } }
    struct SilentSpeech: SpeechProvider {
        let fails: Bool
        let name = "silent"; let isConfigured = true; let isSpeaking = false
        func stop() {}
        func speak(_ text: SanitizedSpokenText, onWord: (@Sendable (Range<Int>) -> Void)?) async throws {
            if fails { throw SpeechError.synthesisFailed("fixture silence") }
        }
    }
    typealias Transport = ManagedSummaryTests.Transport

    func testLocalSpoolBindsSourceAtIngestionAndDuplicatePreservesIt() throws {
        let store = try store(); let url = directory.appendingPathComponent("spool.jsonl")
        let row = event()
        let line = try JSONEncoder().encode(row)
        try line.write(to: url)
        let result = try SpoolDrainer(store: store, spoolURL: url, summaryOriginId: origin).drain()
        XCTAssertEqual(result.inserted, 1)
        let queued = try XCTUnwrap(store.waitingSessions().first)
        XCTAssertEqual(try store.summarySource(eventRowid: queued.latestId), source)
        try line.write(to: url)
        let duplicate = try SpoolDrainer(store: store, spoolURL: url, summaryOriginId: UUID()).drain()
        XCTAssertEqual(duplicate.duplicates, 1)
        XCTAssertEqual(try self.store().summarySource(eventRowid: queued.latestId), source)
    }

    func testCopiedOriginalIdentitySurvivesDifferentRowidsAndPresentationButEditIsNew() throws {
        let first = try store(); let a = try insert(first)
        let other = try store("other")
        try other.insert(event: event("unrelated"))
        let copied = QueuedEvent(id: event().id, createdAtMs: event().createdAtMs + 1, hookEvent: .stop,
                                sessionId: "current-fork", promptId: "new-presentation", lastAssistantMessage: "The export is ready.")
        let b = try insert(other, event: copied, source: source)
        XCTAssertNotEqual(a.latestId, b.latestId)
        XCTAssertEqual(try first.summarySource(eventRowid: a.latestId), try other.summarySource(eventRowid: b.latestId))
        let edited = GatewaySource.localHook(event("edited-event"), originId: origin)
        XCTAssertNotEqual(source.operationId(accountId: account), edited.operationId(accountId: account))
        XCTAssertEqual(try other.eventId(forRowid: b.latestId), event().id)
    }

    func testSourceBindingIsImmutableAndUnknownEventFails() throws {
        let store = try store(); let row = try insert(store)
        try store.bindSummarySource(source, eventId: event().id)
        XCTAssertThrowsError(try store.bindSummarySource(.localHook(event("edited"), originId: origin), eventId: event().id)) {
            XCTAssertEqual($0 as? ManagedSummaryFailure, .sourceIdentityConflict)
        }
        XCTAssertThrowsError(try store.bindSummarySource(source, eventId: "not-in-queue"))
        XCTAssertEqual(try store.summarySource(eventRowid: row.latestId), source)
    }

    func testCoordinatorPersistsReceiptBeforeAudioAndRestoresItOffline() async throws {
        let store = try store(); let row = try insert(store); let op = result()
        let transport = Transport([(200, try GatewayContract.encode(op))])
        try await coordinator(store, transport: transport).prepareNext()
        let cached = try XCTUnwrap(store.storedSummary(sessionId: row.sessionId, eventRowid: row.latestId))
        XCTAssertEqual(cached.receipt, op.receipt)
        XCTAssertFalse(try XCTUnwrap(store.waitingSessions().first).heard, "a paid result is not played audio")
        let offline = Transport([])
        guard case .spoke(let announcement) = try await coordinator(try self.store(), transport: offline).announceNext() else {
            return XCTFail("expected stored announcement")
        }
        XCTAssertEqual(announcement.managedReceipt, op.receipt); XCTAssertNil(announcement.managedFailure)
        let calls = await offline.methods; XCTAssertTrue(calls.isEmpty)
        let bodies = await transport.bodies
        XCTAssertEqual(try JSONDecoder().decode(GatewaySummaryRequest.self, from: XCTUnwrap(bodies.first)).source, source)
    }

    func testMissingSourceDoesNotInventPaidIdentityOrPersistFreeFloor() async throws {
        let store = try store(); try store.insert(event: event()); let transport = Transport([])
        guard case .spoke(let announcement) = try await coordinator(store, transport: transport).announceNext() else {
            return XCTFail("expected free floor")
        }
        XCTAssertEqual(announcement.managedFailure, .missingSourceIdentity); XCTAssertNil(announcement.managedReceipt)
        XCTAssertNil(try store.storedBrief(sessionId: announcement.event.sessionId, eventRowid: announcement.event.latestId))
        let calls = await transport.methods; XCTAssertTrue(calls.isEmpty)
    }

    func testLostResponseReopensThroughCoordinatorByGETAndKeepsFailureVisible() async throws {
        let store = try store(); let row = try insert(store)
        let failed = Transport([], loseFirstResponse: true)
        guard case .spoke(let floor) = try await coordinator(store, transport: failed).announceNext() else { return XCTFail("expected floor") }
        XCTAssertEqual(floor.managedFailure, .outcomeUnknown(operationId: result().operationId))
        XCTAssertNil(try store.storedBrief(sessionId: row.sessionId, eventRowid: row.latestId))
        let recovered = Transport([(200, try GatewayContract.encode(result()))])
        guard case .spoke(let announcement) = try await coordinator(try self.store(), transport: recovered).announceNext(only: row.sessionId) else {
            return XCTFail("expected recovered result")
        }
        XCTAssertEqual(announcement.managedReceipt, result().receipt); XCTAssertNil(announcement.managedFailure)
        let calls = await recovered.methods; XCTAssertEqual(calls, ["GET"])
    }

    func testPendingPreparationDoesNotPoisonMemoryCache() async throws {
        let store = try store(); let row = try insert(store); let op = result()
        let pending = GatewayOperation(version: "1", accountId: op.accountId, operationId: op.operationId,
                                       state: .running, brief: nil, receipt: nil, error: nil)
        let transport = Transport([(202, try GatewayContract.encode(pending)), (200, try GatewayContract.encode(op))])
        let coordinator = try coordinator(store, transport: transport)
        try await coordinator.prepareNext()
        XCTAssertNil(try store.storedBrief(sessionId: row.sessionId, eventRowid: row.latestId))
        try await coordinator.prepareNext()
        guard case .spoke(let announcement) = try await coordinator.announceNext() else { return XCTFail("expected recovered result") }
        XCTAssertEqual(announcement.managedReceipt, op.receipt)
        let calls = await transport.methods; XCTAssertEqual(calls, ["PUT", "GET"])
    }

    func testReceiptWriteFailureRollsBackBriefAndOutboxRecoversOffline() async throws {
        let store = try store(); let row = try insert(store)
        try await store.dbQueue.write { try $0.execute(sql: """
            CREATE TRIGGER fixture_receipt_failure BEFORE INSERT ON brief_receipt BEGIN
                SELECT RAISE(ABORT, 'fixture cache failure'); END;
            """) }
        let transport = Transport([(200, try GatewayContract.encode(result()))])
        try await coordinator(store, transport: transport).prepareNext()
        XCTAssertNil(try store.storedBrief(sessionId: row.sessionId, eventRowid: row.latestId), "receipt and card must commit together")
        try await store.dbQueue.write { try $0.execute(sql: "DROP TRIGGER fixture_receipt_failure") }
        let offline = Transport([])
        try await coordinator(try self.store(), transport: offline).prepareNext()
        XCTAssertEqual(try store.storedSummary(sessionId: row.sessionId, eventRowid: row.latestId)?.receipt, result().receipt)
        let calls = await offline.methods; XCTAssertTrue(calls.isEmpty)
    }

    func testReceiptCannotAttachToAnotherEventOrBeSilentlyErased() throws {
        let store = try store(); let row = try insert(store); let op = result()
        let other = try insert(store, event: event("other-event"))
        XCTAssertThrowsError(try store.saveBrief(op.brief!, sessionId: other.sessionId, eventRowid: other.latestId,
                                               provider: "tranquility-gateway", callsign: nil, managedReceipt: op.receipt))
        try store.saveBrief(op.brief!, sessionId: row.sessionId, eventRowid: row.latestId,
                            provider: "tranquility-gateway", callsign: nil, managedReceipt: op.receipt)
        XCTAssertThrowsError(try store.saveBrief(SessionBrief(topic: "Wrong", happened: "Changed."), sessionId: row.sessionId,
                                               eventRowid: row.latestId, provider: "direct", callsign: nil))
        XCTAssertEqual(try store.storedSummary(sessionId: row.sessionId, eventRowid: row.latestId)?.brief.brief, op.brief)
    }

    func testConcurrentPreparationSharesOneInvocation() async throws {
        let store = try store(); _ = try insert(store)
        let transport = Transport([(200, try GatewayContract.encode(result()))])
        let coordinator = try coordinator(store, transport: transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { try await coordinator.prepareNext() } }
            try await group.waitForAll()
        }
        let calls = await transport.methods; XCTAssertEqual(calls, ["PUT"])
    }

    func testAudioFailureDoesNotLoseReceiptOrSetHeardCursor() async throws {
        let store = try store(); let row = try insert(store)
        let transport = Transport([(200, try GatewayContract.encode(result()))])
        let coordinator = try coordinator(store, transport: transport, speechFails: true)
        let expected = result().receipt
        guard case .interrupted = try await coordinator.announceNext(onWillSpeak: { announcement in
            XCTAssertEqual(announcement.managedReceipt, expected)
            return true
        }) else { return XCTFail("expected audio failure") }
        XCTAssertEqual(try store.storedSummary(sessionId: row.sessionId, eventRowid: row.latestId)?.receipt, expected)
        XCTAssertFalse(try XCTUnwrap(store.waitingSessions().first).heard)
    }

    func testLegacyStoredBriefIsNotRetroactivelyChargedInManagedMode() async throws {
        let store = try store(); let row = try insert(store)
        try store.saveBrief(SessionBrief(topic: "Greeting", happened: "Ready."), sessionId: row.sessionId,
                            eventRowid: row.latestId, provider: "app-greeting", callsign: nil)
        let transport = Transport([])
        guard case .spoke(let announcement) = try await coordinator(store, transport: transport).announceNext() else { return XCTFail("expected existing content") }
        XCTAssertNil(announcement.managedReceipt); XCTAssertNil(announcement.managedFailure)
        let calls = await transport.methods; XCTAssertTrue(calls.isEmpty)
    }

    func testPreCancelledPreparationCannotCreateUncancelledPaidTask() async throws {
        let store = try store(); let row = try insert(store)
        let transport = Transport([(200, try GatewayContract.encode(result()))])
        let coordinator = try coordinator(store, transport: transport)
        try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await coordinator.prepareNext()
        }.value
        XCTAssertNil(try store.storedBrief(sessionId: row.sessionId, eventRowid: row.latestId))
        let calls = await transport.methods; XCTAssertTrue(calls.isEmpty)
        try await coordinator.prepareNext()
        XCTAssertEqual(try store.storedSummary(sessionId: row.sessionId, eventRowid: row.latestId)?.receipt, result().receipt)
    }

    func testMissingReceiptCopyRecoversFromOutboxWithoutNetworking() async throws {
        let store = try store(); let row = try insert(store)
        let transport = Transport([(200, try GatewayContract.encode(result()))])
        try await coordinator(store, transport: transport).prepareNext()
        try await store.dbQueue.write { try $0.execute(sql: "DELETE FROM brief_receipt") }
        let offline = Transport([])
        try await coordinator(try self.store(), transport: offline).prepareNext()
        XCTAssertEqual(try store.storedSummary(sessionId: row.sessionId, eventRowid: row.latestId)?.receipt, result().receipt)
        let calls = await offline.methods; XCTAssertTrue(calls.isEmpty)
    }

    func testRemoteAdapterSourceIsNotRewrittenAsLocal() async throws {
        for (index, namespace) in ["crobot:tenant-fixture", "opencode:installation-fixture"].enumerated() {
            let store = try store("remote-\(index)")
            let remote = GatewaySource(namespace: namespace, taskId: "provider-task", turnId: "provider-turn")
            let row = try insert(store, source: remote)
            let transport = Transport([(200, try GatewayContract.encode(result(source: remote)))])
            try await coordinator(store, transport: transport, outboxName: "remote-outbox-\(index)").prepareNext()
            let bodies = await transport.bodies
            XCTAssertEqual(try JSONDecoder().decode(GatewaySummaryRequest.self, from: XCTUnwrap(bodies.first)).source, remote)
            XCTAssertEqual(try store.storedSummary(sessionId: row.sessionId, eventRowid: row.latestId)?.receipt?.operationId,
                           remote.operationId(accountId: account))
        }
    }

    func testCorruptReceiptInDirectModeDoesNotTriggerPersonalProvider() async throws {
        let store = try store(); let row = try insert(store)
        try await coordinator(store, transport: Transport([(200, try GatewayContract.encode(result()))])).prepareNext()
        try await store.dbQueue.write { try $0.execute(sql: "UPDATE brief_receipt SET receipt=?", arguments: [Data("bad json".utf8)]) }
        let counter = ManagedSummaryTests.Counter(); let speech = SilentSpeech(fails: false)
        let direct = Coordinator(store: store, summarizer: SummarizerChain(providers: [ManagedSummaryTests.Direct(counter: counter)]),
            speech: SpeechChain(preferred: speech, fallback: speech),
            gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent), agents: Agents(),
            recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))
        guard case .spoke(let announcement) = try await direct.announceNext() else { return XCTFail("expected stored content") }
        XCTAssertEqual(announcement.managedFailure, .invalidResponse); XCTAssertNil(announcement.managedReceipt)
        let calls = await counter.calls; XCTAssertEqual(calls, 0)
        XCTAssertEqual(announcement.event.latestId, row.latestId)
    }
}
