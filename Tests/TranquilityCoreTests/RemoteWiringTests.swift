import XCTest
@testable import TranquilityCore

/// The wiring, which is the difference between correct and reachable.
///
/// Each of these pins a join that has no other test, because each one is a
/// place where two correct halves can be connected wrongly and nothing fails.
final class RemoteWiringTests: XCTestCase {

    private func config(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hq.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The registry

    /// Absent means not connected. A machine with no provider draws no remote
    /// rows and starts no poller, which is most machines.
    override func setUp() {
        super.setUp()
        // Not this Mac's binaries. The registry now spawns every installed
        // catalog entry, and a test that read the real search paths would pass
        // or fail by what happens to be installed here (recorded three times
        // on 14 Sep). Each test says what is installed.
        AgentProviders.installedACP = { [] }
    }
    override func tearDown() { AgentProviders.installedACP = { ACPCatalog.installed() }; super.tearDown() }

    /// Not this Mac's ledger either: the real one says OpenCode has been used
    /// here, and a registry test reading it would spawn a fake binary.
    private let ledger = ProviderLedger(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-ledger-\(UUID().uuidString).json"))

    private func opencodeInstalled() -> [(entry: ACPCatalog.Entry, command: [String])] {
        [(ACPCatalog.published.first { $0.id == "opencode" }!, ["/fake/bin/opencode", "acp"])]
    }

    /// **One vendor, one route.** With the binary installed, OpenCode is the
    /// protocol provider this app spawns, and it counts as configured with no
    /// base URL at all: the binary is its address.
    func testAnInstalledAgentIsRegisteredAndConfiguredWithNoAddress() throws {
        AgentProviders.installedACP = opencodeInstalled
        let url = try config(#"{"app":{"base_url":"https://hq.example.test"}}"#)
        let registry = AgentProviders.registry(config: url, secret: { _ in nil }, ledger: ledger)
        XCTAssertEqual(registry.providers.map(\.id), ["opencode"])
        XCTAssertTrue(registry.providers[0] is ServedOpenCodeProvider, "OpenCode is served, not piped (15 Sep 9:11 PM)")
        XCTAssertEqual(registry.configured(config: url).map(\.id), ["opencode"],
                       "a spawnable provider needs no base URL to be polled")
    }

    /// And with the binary installed, a base URL for the same vendor does NOT
    /// add a second provider under the same id: `RemoteDispatchTransport`
    /// resolves by id and would answer through whichever it found first.
    func testTheHTTPRouteYieldsToTheSpawnableOneUnderOneId() throws {
        AgentProviders.installedACP = opencodeInstalled
        let url = try config(#"{"providers":{"opencode":{"base_url":"http://127.0.0.1:4096"}}}"#)
        let built = AgentProviders.registry(config: url, secret: { _ in nil }, ledger: ledger).providers
        XCTAssertEqual(built.map(\.id), ["opencode"])
        XCTAssertTrue(built[0] is ServedOpenCodeProvider, "the app serves it; the address is for machines that cannot")
    }

    /// Registering costs nothing: no process runs until a session is started.
    func testARegisteredProtocolProviderRunsNoProcessUntilStarted() throws {
        AgentProviders.installedACP = { [(ACPCatalog.published[0], ["/definitely/not/a/binary", "acp"])] }
        let url = try config(#"{"app":{"base_url":"https://hq.example.test"}}"#)
        // A missing binary would throw on spawn; building the registry must not spawn.
        XCTAssertNoThrow(AgentProviders.registry(config: url, secret: { _ in nil }, ledger: ledger))
    }

    func testAMachineWithNothingConfiguredGetsAnEmptyRegistry() throws {
        let url = try config(#"{"app":{"base_url":"https://hq.example.test"}}"#)
        XCTAssertTrue(AgentProviders.registry(config: url, secret: { _ in nil }, ledger: ledger)
            .configured(config: url).isEmpty)
    }

    func testALocalServerNeedsOnlyAnAddress() throws {
        let url = try config(#"{"providers":{"opencode":{"base_url":"http://127.0.0.1:4096"}}}"#)
        let ids = AgentProviders.registry(config: url, secret: { _ in nil }, ledger: ledger)
            .configured(config: url).map(\.id)
        XCTAssertEqual(ids, ["opencode"])
    }

    /// **crobot needs BOTH.** A base URL with no key authenticates nothing and
    /// would put a row on the panel that 401s on every poll, which reads as the
    /// agent being broken rather than as setup being unfinished.
    func testCrobotWithNoCredentialIsNotRegisteredAtAll() throws {
        let url = try config(#"{"providers":{"crobot":{"base_url":"https://crobot.example.test"}}}"#)
        // The secret reader is injected rather than read from this Mac. The
        // first version of this test asked the real keychain, passed on a
        // machine with no crobot key and failed on one that had it: the same
        // disk-dependency defect this file's own registry was just fixed for.
        let built = AgentProviders.registry(config: url, secret: { _ in nil }, ledger: ledger)
            .providers.map(\.id)
        XCTAssertFalse(built.contains("crobot"),
                       "a provider with no key would 401 on every poll")

        // And WITH a key it is built, which is the other half: a guard that
        // always refuses is indistinguishable from one that works.
        let withKey = AgentProviders.registry(config: url, secret: { _ in "jrv_probe" }, ledger: ledger)
            .providers.map(\.id)
        XCTAssertTrue(withKey.contains("crobot"))
    }

    // MARK: - The gateway transport

    /// The proxy IS an OpenCode server, so the shared client reaches it one
    /// level deeper with the same bearer token.
    func testTheOpenCodeProxyIsAddressedUnderTheTask() {
        let t = CrobotHTTPTransport(base: URL(string: "https://crobot.example.test")!,
                                    key: "jrv_probe")
        let url = t.taskURL("abc")
        XCTAssertEqual(url?.absoluteString, "https://crobot.example.test/tasks/abc")
    }

    /// crobot is polled. The gateway has an SSE stream per TASK, but a stream
    /// per task is not a stream over the task LIST: subscribing would mean one
    /// connection per row and still polling to learn the rows exist.
    func testTheCrobotProxyDeclaresNoStream() {
        let t = CrobotHTTPTransport(base: URL(string: "https://crobot.example.test")!,
                                    key: "jrv_probe")
        XCTAssertNil(t.opencode("abc").events())
    }

    // MARK: - Which transport answers

    /// **An id is remote if the POLLER has seen it**, not if the registry could
    /// in principle reach it. That is the only honest test: it is the same
    /// snapshot the grid drew the row from, so the reply goes where the row
    /// said it would.
    func testRemotenessIsDecidedByWhatTheGridIsShowing() {
        let poller = AgentPoller(registry: AgentProviderRegistry([]))
        let known = AgentSession.of("s1", provider: "opencode")
        poller.apply(AgentEvent(provider: "opencode", session: known.id,
                                kind: .appeared(known)))

        let isRemote: (String) -> Bool = { poller.snapshot.agent($0) != nil }
        XCTAssertTrue(isRemote(known.id))
        XCTAssertFalse(isRemote("8f14e45f-ceea-467a-9eef-2b9c1b2dc9f0"),
                       "a local session id must not be routed to a provider")
    }

    // MARK: - Events become spool lines

    /// The join that makes everything downstream free. An event the poller
    /// emits has to produce a line the existing drainer accepts, or a remote
    /// agent is visible and silent.
    func testAPollerEventBecomesALineTheDrainerAccepts() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wiring-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(url: dir.appendingPathComponent("q.sqlite"))
        let spool = dir.appendingPathComponent("spool.jsonl")

        var agent = AgentSession.of("s1", provider: "opencode", title: "tidy up")
        agent.repository = "acme/importer"
        let event = AgentEvent(
            provider: "opencode", session: agent.id,
            kind: .said(Turn(id: "t1", at: Date(), role: .agent, text: "Cleaning up.")))

        // Exactly what the app does on `onEvents`.
        let lines = RemoteSpool.lines(for: event, agent: agent)
        RemoteSpool.append(lines, to: spool)
        let drained = try SpoolDrainer(store: store, spoolURL: spool).drain()

        XCTAssertEqual(drained.inserted, 1)
        XCTAssertEqual(drained.malformed, 0)
        XCTAssertEqual(try store.allKnownSessions().first?.sessionId, agent.id)
    }

    // MARK: - The band reads the snapshot

    /// The grid must draw what the poller last saw, without waiting on a
    /// network call. A repaint that blocks is the bug `lastSeenLive` exists to
    /// prevent on the local bands.
    func testTheSnapshotIsReadableSynchronouslyAndDrawsRows() {
        let poller = AgentPoller(registry: AgentProviderRegistry([]))
        var agent = AgentSession.of("s1", provider: "opencode", title: "tidy up")
        agent.state = .inputRequired
        poller.apply(AgentEvent(provider: "opencode", session: agent.id,
                                kind: .appeared(agent)))
        poller.apply(AgentEvent(provider: "opencode", session: agent.id,
                                kind: .asks(PendingRequest(id: "q", session: agent.id,
                                                           asked: "Merge?"))))

        let snapshot = poller.snapshot
        let rows = GridAssembler.rows(GridAssembler.RowInputs(
            waiting: [], known: [], discovered: [], liveById: [:], boundaries: [:],
            switchedOff: [], switchedOn: [],
            evidence: { _, _ in nil }, isHeadless: { _ in false }, family: { [$0] },
            supersedesWaiting: { _, _ in false }, isInFlight: { _ in false },
            recordedTurns: [],
            remote: .init(agents: snapshot.agents, requests: snapshot.requests,
                          unread: [], unreachable: snapshot.unreachable))).rows

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].lamp, .fault, "an agent blocked on a permission shows amber, like a local dialog")
        XCTAssertEqual(rows[0].read, .unread, "a pending request stays unread until answered")
        XCTAssertEqual(rows[0].aux, "Merge?")
    }
}
