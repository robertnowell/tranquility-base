import XCTest
@testable import TranquilityCore

/// Offline is its own state (ruled 22 Sep): a blip shows nothing, a real
/// outage shows once, and coming back runs whatever was waiting.
final class ConnectivityTests: XCTestCase {
    override func tearDown() { Connectivity.installForTesting(nil) }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock(); private var value: T
        init(_ value: T) { self.value = value }
        func update(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
        var get: T { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testABlipShorterThanTheDebounceShowsNothing() async throws {
        let c = Connectivity(debounce: 0.3)
        let heard = Box<[Bool]>([])
        c.observeOffline { v in heard.update { $0.append(v) } }
        c.ingest(true); c.ingest(false)
        XCTAssertFalse(c.isReachable, "the raw reading is immediate")
        try await Task.sleep(for: .milliseconds(100))
        c.ingest(true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(c.isOffline)
        XCTAssertEqual(heard.get, [false], "nothing but the joining value")
    }

    func testASustainedOutageShowsOnceAndClearsOnReturn() async throws {
        let c = Connectivity(debounce: 0.1)
        let heard = Box<[Bool]>([])
        c.observeOffline { v in heard.update { $0.append(v) } }
        c.ingest(false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(c.isOffline)
        c.ingest(false)
        c.ingest(true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(c.isOffline)
        XCTAssertEqual(heard.get, [false, true, false])
    }

    func testReconnectRunsOnlyOnARealReturn() async throws {
        let c = Connectivity(debounce: 10)
        let count = Box(0)
        c.onReconnect { count.update { $0 += 1 } }
        c.ingest(true)   // first reading: not a return
        c.ingest(true)
        c.ingest(false)
        c.ingest(true)   // a return
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(count.get, 1)
    }

    func testWaitingForTheNetworkEndsWhenItArrivesOrTimesOut() async throws {
        let c = Connectivity(debounce: 10)
        c.ingest(false)
        let start = ContinuousClock.now
        await c.waitUntilReachable(timeout: .milliseconds(200))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(150), "offline: waits out the timeout")
        Task { try? await Task.sleep(for: .milliseconds(100)); c.ingest(true) }
        let second = ContinuousClock.now
        await c.waitUntilReachable(timeout: .seconds(5))
        XCTAssertLessThan(ContinuousClock.now - second, .seconds(2), "returns as soon as the network does")
    }

    func testOfflineSummariesSkipTheNetworkAndNeverTouchCredits() async {
        struct Network: SummaryProvider {
            let name = "network"; let isConfigured = true
            let called: Box<Int>
            func brief(for request: SummaryRequest) async throws -> SessionBrief {
                called.update { $0 += 1 }
                return SessionBrief(topic: "T", happened: "network brief.")
            }
        }
        let called = Box(0)
        let c = Connectivity(debounce: 10)
        c.ingest(false)
        Connectivity.installForTesting(c)
        let chain = SummarizerChain(providers: [Network(called: called), DeterministicSummarizer()])
        let summary = await chain.summarize(SummaryRequest(lastAssistantMessage: "The work is ready.",
                                                           projectLabel: "Fixture", hookEvent: .stop))
        XCTAssertEqual(called.get, 0)
        XCTAssertEqual(summary.provider, "deterministic")
    }

    /// Every brief says which rung made it and whether we were offline, so a
    /// fallback the person no longer sees is still visible to us.
    func testEverySummaryRecordsItsProviderAndOfflineness() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("summary-track-\(UUID())")
        Track.resetForTesting(); defer { Track.detach(); Track.resetForTesting() }
        Track.configure(directory: dir, installId: "install-x")
        let seen = Box<[TrackEvent]>([])
        Track.attach { e in if e.name == "summary" { seen.update { $0.append(e) } } }
        let c = Connectivity(debounce: 10); c.ingest(false)
        Connectivity.installForTesting(c)
        _ = await SummarizerChain(providers: [DeterministicSummarizer()]).summarize(
            SummaryRequest(lastAssistantMessage: "The work is ready.", projectLabel: "Fixture", hookEvent: .stop))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(seen.get.first?.properties["provider"], .token("deterministic"))
        XCTAssertEqual(seen.get.first?.properties["offline"], .bool(true))
    }
}
