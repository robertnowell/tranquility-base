import Foundation
import XCTest
@testable import TranquilityCore

final class ManagedSummaryTests: XCTestCase {
    let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let source = GatewaySource(namespace: "local:fixture", taskId: "original-session", turnId: "turn-1")
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("managed-summary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    var request: SummaryRequest {
        SummaryRequest(lastAssistantMessage: "The export is ready. All tests passed.", projectLabel: "Export", previousGoal: "Ship the export", managedSource: source)
    }
    func outbox(_ name: String = "outbox") throws -> ManagedSummaryOutbox {
        try ManagedSummaryOutbox(url: directory.appendingPathComponent("\(name).sqlite"))
    }
    func client(_ transport: any GatewayTransport, name: String = "outbox") throws -> ManagedSummaryClient {
        ManagedSummaryClient(accountId: account, transport: transport, outbox: try outbox(name))
    }
    func result(brief: SessionBrief = SessionBrief(topic: "Export", happened: "All tests passed.")) -> GatewayOperation {
        let id = source.operationId(accountId: account)
        return GatewayOperation(version: "1", accountId: account.uuidString.lowercased(), operationId: id, state: .succeeded,
            brief: brief, receipt: GatewayReceipt(id: "22222222-2222-4222-8222-222222222222",
                accountId: account.uuidString.lowercased(), operationId: id, currency: "USD", chargedMicros: "20000",
                pricebookVersion: "fixture-summary-v1", settledAt: "2026-09-13T19:00:00.000Z",
                balanceAfter: GatewayBalance(availableMicros: "9980000", reservedMicros: "0", ledgerSequence: "3")), error: nil)
    }

    actor Transport: GatewayTransport {
        var replies: [(Int, Data)]
        var calls: [(String, String, Data?)] = []
        var loseFirstResponse: Bool
        init(_ replies: [(Int, Data)], loseFirstResponse: Bool = false) { self.replies = replies; self.loseFirstResponse = loseFirstResponse }
        func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
            calls.append((method, path, body))
            if loseFirstResponse { loseFirstResponse = false; throw URLError(.networkConnectionLost) }
            guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
            return replies.removeFirst()
        }
        var methods: [String] { calls.map(\.0) }
        var bodies: [Data] { calls.compactMap(\.2) }
    }
    actor Counter { var calls = 0; func hit() { calls += 1 } }
    struct Direct: SummaryProvider {
        let name = "direct-fixture"; let isConfigured = true; let counter: Counter
        func brief(for request: SummaryRequest) async throws -> SessionBrief {
            await counter.hit(); return SessionBrief(topic: "Export", happened: "Ready.")
        }
    }

    func testFrozenFixturesAndUTF8IdentityMatchServiceVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/gateway/v1")
        struct Vectors: Decodable { let accountId: UUID; let vectors: [String: String] }
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: root.appendingPathComponent("identity-vectors.json")))
        for (name, id) in vectors.vectors {
            let body = try Data(contentsOf: root.appendingPathComponent("fixtures/\(name)"))
            let fixture = try JSONDecoder().decode(GatewaySummaryRequest.self, from: body)
            XCTAssertEqual(fixture.version, "1")
            XCTAssertEqual(fixture.source.operationId(accountId: vectors.accountId), id)
            XCTAssertEqual(try JSONDecoder().decode(GatewaySummaryRequest.self, from: GatewayContract.encode(fixture)), fixture)
        }
    }

    func testSameTurnIdentityIsDeviceAndPresentationIndependentButEditedTurnIsNew() {
        XCTAssertEqual(source.operationId(accountId: account), GatewaySource(namespace: source.namespace, taskId: source.taskId, turnId: source.turnId).operationId(accountId: account))
        XCTAssertNotEqual(source.operationId(accountId: account), GatewaySource(namespace: source.namespace, taskId: source.taskId, turnId: "edited-turn").operationId(accountId: account))
        XCTAssertNotEqual(source.operationId(accountId: account), source.operationId(accountId: UUID()))
    }

    func testManagedDeliveryPreservesBriefReceiptAndNeverCallsDirectFallback() async throws {
        let op = result(); let transport = Transport([(200, try GatewayContract.encode(op))]); let counter = Counter()
        let provider = ManagedSummaryProvider(client: try client(transport))
        let summary = await SummarizerChain(providers: [provider, Direct(counter: counter)]).summarize(request)
        XCTAssertEqual(summary.brief, op.brief); XCTAssertEqual(summary.managedReceipt, op.receipt)
        XCTAssertNil(summary.managedFailure)
        let calls = await counter.calls; XCTAssertEqual(calls, 0)
        let methods = await transport.methods; XCTAssertEqual(methods, ["PUT"])
    }

    func testLostResponseAfterServerSuccessResumesByGETWithSameReceiptAfterRestart() async throws {
        let op = result(); let encoded = try GatewayContract.encode(op)
        let first = Transport([], loseFirstResponse: true)
        do { _ = try await client(first).summarize(source: source, request: request); XCTFail("expected uncertainty") }
        catch { XCTAssertEqual(error as? ManagedSummaryFailure, .outcomeUnknown(operationId: op.operationId)) }
        let second = Transport([(200, encoded)])
        let restored = try await client(second).summarize(source: source, request: request)
        XCTAssertEqual(restored, op)
        let methods = await second.methods; XCTAssertEqual(methods, ["GET"])
        let offline = Transport([])
        let cached = try await client(offline).summarize(source: source, request: request)
        XCTAssertEqual(cached, op)
        let offlineMethods = await offline.methods; XCTAssertEqual(offlineMethods, [])
    }

    func testFrozenOutboxWinsOverDriftingContextAfterRestart() async throws {
        let first = Transport([], loseFirstResponse: true)
        _ = try? await client(first).summarize(source: source, request: request)
        var drifted = request; drifted.previousGoal = "A later goal"; drifted.gitBranch = "later-branch"
        let next = Transport([(404, Data("{\"error\":{\"code\":\"not_found\"}}".utf8)), (200, try GatewayContract.encode(result()))])
        _ = try await client(next).summarize(source: source, request: drifted)
        let bodies = await next.bodies
        let sent = try JSONDecoder().decode(GatewaySummaryRequest.self, from: XCTUnwrap(bodies.first))
        XCTAssertEqual(sent.input.previousGoal, request.previousGoal); XCTAssertNil(sent.input.gitBranch)
        let methods = await next.methods; XCTAssertEqual(methods, ["GET", "PUT"])
    }

    func testTwoOutboxInstancesRaceToFreezeOneRequest() async throws {
        let first = try outbox(); let second = try outbox()
        let account = account.uuidString.lowercased(); let id = source.operationId(accountId: self.account)
        async let a = Task.detached { try first.prepare(account: account, id: id, request: Data("first".utf8)).request }.value
        async let b = Task.detached { try second.prepare(account: account, id: id, request: Data("second".utf8)).request }.value
        let results = try await (a, b); XCTAssertEqual(results.0, results.1)
    }

    func testAuthFailureRemainsVisibleAlongsideFreeFloorAndNeverFallsThroughToBYOK() async throws {
        let transport = Transport([(401, Data("{\"error\":{\"code\":\"auth_required\"}}".utf8))]); let counter = Counter()
        let summary = await SummarizerChain(providers: [ManagedSummaryProvider(client: try client(transport)), Direct(counter: counter)]).summarize(request)
        XCTAssertEqual(summary.provider, "deterministic-fallback"); XCTAssertNil(summary.managedReceipt)
        XCTAssertEqual(summary.managedFailure, .refused(code: "auth_required", operationId: source.operationId(accountId: account)))
        let calls = await counter.calls; XCTAssertEqual(calls, 0)
    }

    func testPendingIsTruthfullyDegradedNotChargedSuccess() async throws {
        let op = GatewayOperation(version: "1", accountId: account.uuidString.lowercased(), operationId: source.operationId(accountId: account),
            state: .reconciling, brief: nil, receipt: nil, error: .init(code: "provider_uncertain"))
        let transport = Transport([(202, try GatewayContract.encode(op))])
        let summary = await SummarizerChain(managed: ManagedSummaryProvider(client: try client(transport))).summarize(request)
        XCTAssertEqual(summary.managedFailure, .pending(operationId: op.operationId, state: .reconciling)); XCTAssertNil(summary.managedReceipt)
    }

    func testManagedGroundingScrubsWithoutIndependentPaidRetry() async throws {
        let op = result(brief: SessionBrief(topic: "Export", happened: "All 927 tests passed. The export is ready."))
        let transport = Transport([(200, try GatewayContract.encode(op))])
        let summary = await SummarizerChain(managed: ManagedSummaryProvider(client: try client(transport))).summarize(request)
        XCTAssertFalse(summary.spoken.text.contains("927")); XCTAssertTrue(summary.provider.hasSuffix("+digit-scrubbed"))
        XCTAssertEqual(summary.managedReceipt, op.receipt)
        let methods = await transport.methods; XCTAssertEqual(methods, ["PUT"])
    }

    func testManagedScrubCannotReintroduceNumbersFromCardFallbackOrTopic() async throws {
        let op = result(brief: SessionBrief(topic: "Export 814", happened: "All 927 tests passed.", recap: "The 625 tests passed."))
        let transport = Transport([(200, try GatewayContract.encode(op))])
        let summary = await SummarizerChain(managed: ManagedSummaryProvider(client: try client(transport))).summarize(request)
        for number in ["814", "927", "625"] { XCTAssertFalse(summary.spoken.text.contains(number)) }
        let methods = await transport.methods; XCTAssertEqual(methods, ["PUT"])
    }

    func testMissingIdentityAndCorrectiveRetryRefuseBeforeNetworking() async throws {
        let transport = Transport([]); let provider = ManagedSummaryProvider(client: try client(transport))
        var noSource = request; noSource.managedSource = nil
        do { _ = try await provider.delivery(for: noSource); XCTFail("must require identity") }
        catch { XCTAssertEqual(error as? ManagedSummaryFailure, .missingSourceIdentity) }
        var retry = request; retry.correctiveNote = "try again"
        do { _ = try await provider.delivery(for: retry); XCTFail("must refuse changed paid retry") }
        catch { XCTAssertEqual(error as? ManagedSummaryFailure, .correctiveRetryNotAllowed) }
        let methods = await transport.methods; XCTAssertTrue(methods.isEmpty)
    }

    func testEmptySourceAndBYOKMakeNoGatewayCalls() async throws {
        let transport = Transport([]); var empty = request; empty.lastAssistantMessage = "   "
        let summary = await SummarizerChain(managed: ManagedSummaryProvider(client: try client(transport))).summarize(empty)
        XCTAssertEqual(summary.provider, "empty-source"); XCTAssertNil(summary.managedReceipt)
        let counter = Counter(); let direct = await SummarizerChain(providers: [Direct(counter: counter)]).summarize(request)
        XCTAssertEqual(direct.provider, "direct-fixture"); XCTAssertNil(direct.managedReceipt)
        let methods = await transport.methods; XCTAssertTrue(methods.isEmpty)
    }

    func testForeignReceiptMalformedMoneyAndUnknownStateAreNotCachedAsSuccess() async throws {
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: GatewayContract.encode(result())) as? [String: Any])
        for mutation in ["account", "money", "state", "status", "currency", "timestamp"] {
            var object = valid
            if mutation == "state" { object["state"] = "future-state" }
            else if mutation != "status" {
                var receipt = try XCTUnwrap(object["receipt"] as? [String: Any])
                if mutation == "account" { receipt["accountId"] = UUID().uuidString.lowercased() }
                if mutation == "money" { receipt["chargedMicros"] = "0.02" }
                if mutation == "currency" { receipt["currency"] = "EUR" }
                if mutation == "timestamp" { receipt["settledAt"] = "not-a-date" }
                object["receipt"] = receipt
            }
            let t = Transport([(mutation == "status" ? 202 : 200, try JSONSerialization.data(withJSONObject: object))])
            do { _ = try await client(t, name: mutation).summarize(source: source, request: request); XCTFail("must reject \(mutation)") }
            catch { XCTAssertEqual(error as? ManagedSummaryFailure, .invalidResponse) }
        }
    }

    func testTransportRequiresSecureOriginOrExplicitLoopbackFixture() throws {
        for address in ["http://example.com", "http://localhost:8000", "https://example.com/path", "https://user:password@example.com", "https://example.com?leak=yes"] {
            XCTAssertThrowsError(try GatewayHTTPTransport(base: URL(string: address)!, bearer: { "fixture" }))
        }
        XCTAssertNoThrow(try GatewayHTTPTransport(base: URL(string: "http://127.0.0.1:8000")!, allowLoopbackFixture: true, bearer: { "fixture" }))
    }

    func testCancelledBeforeNetworkingMakesNoTransportCall() async throws {
        let transport = Transport([]); let c = try client(transport); let source = source; let req = request
        let task = Task { try await Task.sleep(for: .seconds(10)); return try await c.summarize(source: source, request: req) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let methods = await transport.methods; XCTAssertTrue(methods.isEmpty)
    }

    func testCancellationAfterSendingKeepsOutboxForGETReconciliation() async throws {
        struct CancelledTransport: GatewayTransport {
            func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
                throw CancellationError()
            }
        }
        do { _ = try await client(CancelledTransport()).summarize(source: source, request: request); XCTFail("cancelled") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        let resumed = Transport([(200, try GatewayContract.encode(result()))])
        let outcome = try await client(resumed).summarize(source: source, request: request)
        XCTAssertEqual(outcome, result())
        let methods = await resumed.methods; XCTAssertEqual(methods, ["GET"])
    }

    /// Opt-in LOCAL HTTP/real PostgreSQL integration, never a paid provider.
    /// The fixture server rejects every credential except its public test token.
    func testLoopbackPrivateServiceEndToEnd() async throws {
        guard let url = ProcessInfo.processInfo.environment["TB_GATEWAY_FIXTURE_URL"] else {
            throw XCTSkip("local private-service fixture not requested")
        }
        let transport = try GatewayHTTPTransport(base: XCTUnwrap(URL(string: url)), allowLoopbackFixture: true, bearer: { "fixture-only-not-a-secret" })
        let connected = try await ManagedSummaryClient.connect(transport: transport)
        XCTAssertEqual(connected.balance.availableMicros, "10000000")
        let connectedAgain = try await ManagedSummaryClient.connect(transport: transport)
        XCTAssertEqual(connectedAgain.accountId, connected.accountId)
        let account = try XCTUnwrap(UUID(uuidString: connected.accountId))
        actor LoseReply: GatewayTransport {
            let underlying: any GatewayTransport
            init(_ underlying: any GatewayTransport) { self.underlying = underlying }
            func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
                _ = try await underlying.request(method: method, path: path, body: body)
                throw URLError(.networkConnectionLost)
            }
        }
        let queueURL = directory.appendingPathComponent("queue.sqlite")
        let queue = try QueueStore(url: queueURL)
        let event = QueuedEvent(id: source.turnId, createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                                hookEvent: .stop, sessionId: source.taskId, promptId: source.turnId,
                                lastAssistantMessage: request.lastAssistantMessage)
        try queue.insert(event: event, summarySource: source)
        let row = try XCTUnwrap(queue.waitingSessions().first)
        func coordinator(_ store: QueueStore, _ http: any GatewayTransport, _ name: String = "outbox") throws -> Coordinator {
            let client = ManagedSummaryClient(accountId: account, transport: http, outbox: try outbox(name))
            let speech = CreditedCoordinatorTests.SilentSpeech(fails: false)
            return Coordinator(store: store, summarizer: SummarizerChain(managed: ManagedSummaryProvider(client: client)),
                speech: SpeechChain(preferred: speech, fallback: speech),
                gate: InterruptGate(minimumIdleSeconds: 0, signals: .quiescent),
                enrolment: EnrolmentRegistry(url: directory.appendingPathComponent("enrolled.json")),
                agents: CreditedCoordinatorTests.Agents(),
                recovery: RecoveryChain(providers: [], maxAttemptsPerProvider: 1, backoff: [0]))
        }
        try await coordinator(queue, LoseReply(transport)).prepareNext()
        XCTAssertNil(try queue.storedBrief(sessionId: row.sessionId, eventRowid: row.latestId))
        let reopened = try QueueStore(url: queueURL)
        try await coordinator(reopened, transport).prepareNext()
        let receipt = try XCTUnwrap(reopened.storedSummary(sessionId: row.sessionId, eventRowid: row.latestId)?.receipt)
        XCTAssertEqual(receipt.operationId, source.operationId(accountId: account))
        XCTAssertEqual(receipt.chargedMicros, "20000"); XCTAssertEqual(receipt.balanceAfter.availableMicros, "9980000")
        XCTAssertFalse(try XCTUnwrap(reopened.waitingSessions().first).heard)
        let offline = Transport([])
        guard case .spoke(let announcement) = try await coordinator(try QueueStore(url: queueURL), offline).announceNext() else {
            return XCTFail("expected offline receipt-bearing announcement")
        }
        XCTAssertEqual(announcement.managedReceipt, receipt); XCTAssertNil(announcement.managedFailure)
        let offlineCalls = await offline.methods; XCTAssertTrue(offlineCalls.isEmpty)
        // Independent queue and outbox model another viewing device. Imported
        // source is unchanged, while local rowids differ. No actual second Mac.
        let other = try QueueStore(url: directory.appendingPathComponent("other-queue.sqlite"))
        try other.insert(event: QueuedEvent(createdAtMs: 0, hookEvent: .userPromptSubmit, sessionId: "unrelated"))
        try other.insert(event: event, summarySource: source)
        let otherRow = try XCTUnwrap(other.waitingSessions().first)
        XCTAssertNotEqual(otherRow.latestId, row.latestId)
        try await coordinator(other, transport, "other-device").prepareNext()
        XCTAssertEqual(try other.storedSummary(sessionId: otherRow.sessionId, eventRowid: otherRow.latestId)?.receipt, receipt)
        let balance = try await ManagedSummaryClient(accountId: account, transport: transport, outbox: try outbox()).balance()
        XCTAssertEqual(balance.availableMicros, "9980000"); XCTAssertEqual(balance.reservedMicros, "0")
    }
}
