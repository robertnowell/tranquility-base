import Foundation
import XCTest
@testable import TranquilityCore

final class ManagedCreditSessionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("credit-session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private final class Identity: @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        func set(_ token: String?) { lock.lock(); self.token = token; lock.unlock() }
        func read() -> ManagedCreditSession.Identity? {
            lock.lock(); defer { lock.unlock() }
            return token.map { .init(hub: URL(string: "https://fixture.invalid")!, token: $0) }
        }
    }
    private final class Display: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CreditStanding = .notOnCredits(connectAgain: false)
        private var valid: @Sendable () -> Bool = { true }
        func publish(_ value: CreditStanding, _ valid: @escaping @Sendable () -> Bool) {
            lock.lock(); self.value = value; self.valid = valid; lock.unlock()
        }
        var current: CreditStanding {
            lock.lock(); let value = value; let valid = valid; lock.unlock()
            return valid() ? value : .notOnCredits(connectAgain: false)
        }
    }
    /// Deterministic suspension, including a transport that ignores cancellation.
    private actor Gate {
        private var entered = false
        private var observer: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func pause() async {
            entered = true; observer?.resume(); observer = nil
            await withCheckedContinuation { release = $0 }
        }
        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { observer = $0 }
        }
        func open() { release?.resume(); release = nil }
    }
    private actor Gateway: GatewayTransport {
        let account: String
        var available = 10_000_000
        var sequence = 1
        var posts = 0
        var puts = 0
        var gets = 0
        var invalidations = 0
        var failure: String?
        var balanceFailure = false
        var postGate: Gate?
        var putGate: Gate?
        var balanceGate: Gate?
        init(_ account: String) { self.account = account }
        func setBalance(_ value: Int, sequence: Int) { available = value; self.sequence = sequence }
        func refuse(_ code: String?) { failure = code }
        func failBalance() { balanceFailure = true }
        func holdPost(_ gate: Gate) { postGate = gate }
        func holdPut(_ gate: Gate) { putGate = gate }
        func holdBalance(_ gate: Gate) { balanceGate = gate }
        func invalidate() { invalidations += 1 }
        func counts() -> (posts: Int, puts: Int, gets: Int) { (posts, puts, gets) }
        func balance() -> GatewayBalance {
            GatewayBalance(availableMicros: String(available), reservedMicros: "0", ledgerSequence: String(sequence))
        }
        func request(method: String, path: String, body: Data?) async throws -> (status: Int, body: Data) {
            if method == "POST" {
                posts += 1
                let gate = postGate; postGate = nil
                await gate?.pause()
                return (200, try GatewayContract.encode(GatewayAccount(version: "1", accountId: account, currency: "USD", balance: balance())))
            }
            XCTAssertTrue(path.contains(account), "an account URL cannot travel over another account's transport")
            if path.hasSuffix("/balance") {
                gets += 1
                let snapshot = balance()
                let gate = balanceGate; balanceGate = nil
                await gate?.pause()
                if balanceFailure { return (503, Data(#"{"error":{"code":"service_unavailable"}}"#.utf8)) }
                return (200, try GatewayContract.encode(snapshot))
            }
            guard method == "PUT" else { return (404, Data()) }
            puts += 1
            if let failure { return (402, Data("{\"error\":{\"code\":\"\(failure)\"}}".utf8)) }
            let gate = putGate; putGate = nil
            await gate?.pause()
            available -= 20_000; sequence += 1
            let operation = String(path.split(separator: "/").last!)
            let receipt = GatewayReceipt(id: UUID().uuidString.lowercased(), accountId: account,
                operationId: operation, currency: "USD", chargedMicros: "20000", pricebookVersion: "fixture",
                settledAt: "2026-09-16T00:00:00Z", balanceAfter: balance())
            let brief = SessionBrief(topic: "Fixture", happened: "The work is ready.")
            return (200, try GatewayContract.encode(GatewayOperation(version: "1", accountId: account,
                operationId: operation, state: .succeeded, brief: brief, receipt: receipt, error: nil)))
        }
    }
    private let a = "7f3c2a10-1111-4222-8333-444455556666"
    private let b = "7f3c2a10-1111-4222-8333-444455556667"
    private func request(_ turn: String = "one") -> SummaryRequest {
        SummaryRequest(lastAssistantMessage: "The work is ready.", projectLabel: "Fixture", hookEvent: .stop,
                       managedSource: GatewaySource(namespace: "fixture", taskId: "task", turnId: turn))
    }
    private func make(_ identity: Identity, _ display: Display, _ first: Gateway, _ second: Gateway? = nil) -> ManagedCreditSession {
        ManagedCreditSession(identity: { identity.read() }, outboxURL: directory.appendingPathComponent("outbox.sqlite"),
            connect: { value, _ in
                let server = value.token == "A" ? first : (second ?? first)
                return .init(transport: server, invalidate: { await server.invalidate() })
            }, publish: { display.publish($0, $1) })
    }
    private func balance(_ display: Display, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case let .good(value, _) = display.current else {
            XCTFail("not ready: \(display.current)", file: file, line: line); return nil
        }
        return value
    }

    func testFreshSignInUsesTheExistingChainWithoutAKeyOrRestart() async throws {
        let identity = Identity(), display = Display(), gateway = Gateway(a)
        let session = make(identity, display, gateway)
        let chain = SummarizerChain(providers: [session, DeterministicSummarizer()])
        await session.refresh()
        let before = await gateway.counts()
        XCTAssertEqual(before.posts, 0)
        identity.set("A")
        await session.refresh()
        XCTAssertEqual(balance(display), "10000000")
        let probes = Prerequisites.Probes(tmuxPath: { "/fixture/tmux" }, hooksProblem: { _ in nil },
            hasSecret: { _ in false }, hubStatus: { .init(connected: true, detail: "signed in") },
            creditStanding: { display.current })
        XCTAssertTrue(Prerequisites.allRequiredSatisfied(Prerequisites.snapshot(probes)))
        let summary = await chain.summarize(request())
        await session.waitForBalanceUpdates()
        XCTAssertEqual(summary.provider, "tranquility-gateway")
        XCTAssertEqual(summary.managedReceipt?.accountId, a)
        XCTAssertEqual(summary.managedReceipt?.chargedMicros, "20000")
        XCTAssertEqual(balance(display), "9980000")
        let after = await gateway.counts()
        XCTAssertEqual(after.posts, 1); XCTAssertEqual(after.puts, 1)
    }

    func testAccountSwitchWithoutExplicitRefreshUsesANewAccountAndOutboxKey() async throws {
        let identity = Identity(), display = Display(), first = Gateway(a), second = Gateway(b)
        identity.set("A")
        let session = make(identity, display, first, second)
        let old = try await session.delivery(for: request())
        identity.set("B")
        XCTAssertEqual(display.current, .notOnCredits(connectAgain: false), "old standing invalidates immediately")
        let new = try await session.delivery(for: request())
        XCTAssertEqual(old.receipt?.accountId, a); XCTAssertEqual(new.receipt?.accountId, b)
        XCTAssertNotEqual(old.receipt?.operationId, new.receipt?.operationId)
        let counts = await second.counts()
        XCTAssertEqual(counts.posts, 1); XCTAssertEqual(counts.puts, 1)
    }

    func testRemovingTokenCannotReplayAnOldAccountsSummary() async throws {
        let identity = Identity(), display = Display(), gateway = Gateway(a)
        identity.set("A")
        let session = make(identity, display, gateway)
        _ = try await session.delivery(for: request())
        identity.set(nil)
        XCTAssertEqual(display.current, .notOnCredits(connectAgain: false))
        await session.refresh()
        do { _ = try await session.delivery(for: request()); XCTFail("signed-out request succeeded") }
        catch { XCTAssertEqual(error as? ManagedSummaryFailure, .refused(code: "not_connected", operationId: nil)) }
        let counts = await gateway.counts()
        XCTAssertEqual(counts.puts, 1)
    }

    func testCachedReceiptDoesNotRaiseTheBalanceOrInvokeTheProviderAgain() async throws {
        let identity = Identity(), display = Display(), gateway = Gateway(a)
        identity.set("A")
        let session = make(identity, display, gateway)
        let original = try await session.delivery(for: request())
        await gateway.setBalance(8_200_000, sequence: 100)
        let replay = try await session.delivery(for: request())
        await session.waitForBalanceUpdates()
        XCTAssertEqual(replay.receipt, original.receipt)
        XCTAssertTrue(replay.receiptWasReplayed)
        XCTAssertEqual(balance(display), "8200000")
        let counts = await gateway.counts()
        XCTAssertEqual(counts.puts, 1)
    }

    func testReplayingSuccessCannotClearAnOutOfCreditsWarningEvenWithAPositiveBalance() async throws {
        let identity = Identity(), display = Display(), gateway = Gateway(a)
        identity.set("A")
        let session = make(identity, display, gateway)
        _ = try await session.delivery(for: request())
        await session.waitForBalanceUpdates()
        await gateway.refuse("insufficient_credit")
        do { _ = try await session.delivery(for: request("two")); XCTFail("expected refusal") } catch {}
        XCTAssertEqual(display.current.line, "Add credits")
        _ = try await session.delivery(for: request())
        await session.waitForBalanceUpdates()
        XCTAssertEqual(display.current.line, "Add credits")
        await gateway.refuse(nil)
        _ = try await session.delivery(for: request("three"))
        await session.waitForBalanceUpdates()
        XCTAssertNil(display.current.line, "new successful work plus fresh balance can restore readiness")
    }

    func testOldPaidResponseIsSavedButCannotPublishIntoTheNextAccount() async throws {
        let identity = Identity(), display = Display(), first = Gateway(a), second = Gateway(b), gate = Gate()
        identity.set("A"); await first.holdPut(gate)
        let session = make(identity, display, first, second)
        let chain = SummarizerChain(providers: [session])
        let input = request()
        let pending = Task { await chain.summarize(input) }
        await gate.waitForEntry()
        identity.set("B"); await session.refresh()
        XCTAssertEqual(balance(display), "10000000")
        await gate.open()
        let discarded = await pending.value
        XCTAssertEqual(discarded.provider, "none", "account-change cancellation must not create a floor")
        XCTAssertNil(discarded.managedReceipt)
        XCTAssertEqual(balance(display), "10000000")
        // Reconnect A: its completed operation must replay, not spend twice.
        identity.set("A")
        let replay = try await session.delivery(for: request())
        XCTAssertTrue(replay.receiptWasReplayed)
        XCTAssertEqual(replay.receipt?.accountId, a)
        let counts = await first.counts()
        XCTAssertEqual(counts.puts, 1)
    }

    func testSwitchDuringAccountResolutionPreventsAnyPaidRequestForTheOldIdentity() async throws {
        let identity = Identity(), display = Display(), first = Gateway(a), second = Gateway(b), gate = Gate()
        identity.set("A"); await first.holdPost(gate)
        let session = make(identity, display, first, second)
        let input = request()
        let pending = Task { try await session.delivery(for: input) }
        await gate.waitForEntry()
        identity.set("B"); await session.refresh()
        await gate.open()
        do { _ = try await pending.value; XCTFail("old work survived") } catch { XCTAssertTrue(error is CancellationError) }
        let counts = await first.counts()
        XCTAssertEqual(counts.puts, 0)
        XCTAssertEqual(balance(display), "10000000")
    }

    func testAnOlderBalanceResponseCannotOverwriteANewerLedgerSequence() async throws {
        let identity = Identity(), display = Display(), gateway = Gateway(a), gate = Gate()
        identity.set("A")
        let session = make(identity, display, gateway)
        await session.refresh()
        await gateway.holdBalance(gate)
        let older = Task { await session.refresh() }
        await gate.waitForEntry()
        await gateway.setBalance(8_200_000, sequence: 100)
        await session.refresh()
        await gate.open(); await older.value
        XCTAssertEqual(balance(display), "8200000")
    }

    func testBalanceOutageDoesNotDiscardAPaidSuccessfulReceipt() async throws {
        let identity = Identity(), display = Display(), gateway = Gateway(a)
        identity.set("A")
        let session = make(identity, display, gateway)
        await gateway.failBalance()
        let delivery = try await session.delivery(for: request())
        await session.waitForBalanceUpdates()
        XCTAssertEqual(delivery.receipt?.chargedMicros, "20000")
        // A10: the summary was on credits and paid for; only the number is
        // stale. Nothing amber, the row stays on credits, and the detail says
        // exactly which of the two facts is missing.
        XCTAssertNil(display.current.line, "a paid success is never amber")
        XCTAssertTrue(display.current.isOnCredits)
        XCTAssertTrue(display.current.detail.contains("balance could not be refreshed"), display.current.detail)
        XCTAssertFalse(display.current.detail.contains("floor"), display.current.detail)
    }

    func testAnUnreachableBalanceCheckAtLaunchIsNotAFloor() async throws {
        let identity = Identity(), display = Display(), gateway = Gateway(a)
        identity.set("A")
        let session = make(identity, display, gateway)
        await gateway.failBalance()
        await session.refresh()
        // 22 Sep: launched before the network was up, the one check failed,
        // and "Credits unavailable right now" sat on the grid for ninety
        // minutes with credits fine. No summary ran, so nothing fell back.
        XCTAssertNil(display.current.line, "\(display.current)")
        XCTAssertEqual(display.current, .onCredits)
    }

    private func failureRecords(in dir: URL) -> [FailureEvent] {
        Failures.flush()
        guard let text = try? String(contentsOf: dir.appendingPathComponent("failures.jsonl"), encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(FailureEvent.self, from: Data($0.utf8)) }
    }

    /// Online, a gateway that gives no answer is our fault: it reaches
    /// diagnostics with a reason, and the reason never carries the account.
    /// Offline it is not a fault and records nothing (ruled 22 Sep).
    func testAServiceFaultOnlineIsReportedAndOfflineIsNot() async throws {
        Failures.resetForTesting(); defer { Failures.resetForTesting(); Connectivity.installForTesting(nil) }
        let dir = directory.appendingPathComponent("failures")
        Failures.configure(directory: dir)
        let identity = Identity(), display = Display(), gateway = Gateway(a)
        identity.set("A")
        let session = make(identity, display, gateway)
        await gateway.failBalance()

        let offline = Connectivity(debounce: 10); offline.ingest(false)
        Connectivity.installForTesting(offline)
        await session.refresh()
        XCTAssertTrue(failureRecords(in: dir).isEmpty, "offline is not a fault")

        Connectivity.installForTesting(nil)
        await session.refresh()
        let records = failureRecords(in: dir).filter { $0.kind == .creditsService }
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records.first?.reason.hasPrefix("balance check:") == true, records.first?.reason ?? "")
        XCTAssertFalse(records.first?.reason.contains(a) == true, "the account id never leaves")
    }

    func testStoredTokenAloneDoesNotWaiveTheDirectKeyRequirement() {
        let probes = Prerequisites.Probes(tmuxPath: { "/fixture/tmux" }, hooksProblem: { _ in nil },
            hasSecret: { _ in false }, hubStatus: { .init(connected: true, detail: "signed in") }, creditStanding: { .onCredits })
        XCTAssertFalse(Prerequisites.allRequiredSatisfied(Prerequisites.snapshot(probes)))
    }

    func testAStalledBalanceReadCannotDelayADeliveredSummary() async throws {
        let identity = Identity(), display = Display(), gateway = Gateway(a), gate = Gate()
        identity.set("A")
        let session = make(identity, display, gateway)
        await session.refresh()
        await gateway.holdBalance(gate)
        let delivered = try await session.delivery(for: request())
        await gate.waitForEntry()
        XCTAssertEqual(delivered.receipt?.chargedMicros, "20000", "delivery returned before the balance response existed")
        await gate.open()
        await session.waitForBalanceUpdates()
        XCTAssertEqual(balance(display), "9980000")
    }
}
