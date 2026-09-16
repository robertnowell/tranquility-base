import XCTest
@testable import TranquilityCore

/// **The product loop, driven end to end against a real OpenCode**, with
/// everything but AppKit and the microphone: the registry's own provider,
/// the poller, the spool the hooks share, the drainer, the store, and the
/// coordinator's dispatch. What the app does between New Agent and the next
/// spoken turn, asserted at every seam Robert found broken by hand on
/// 15 Sep: the words reached the agent, the agent's words are the session's
/// latest turn (not "finished a turn"), the session is waiting for him with
/// no local process, the row is named by his words and then the model's,
/// wears its own harness, and has a door.
///
/// Gated on TB_LIVE_OPENCODE_LOOP=1 and TB_TOY; inert everywhere else.
final class LiveOpenCodeLoop: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TB_LIVE_OPENCODE_LOOP"] == nil,
                      "set TB_LIVE_OPENCODE_LOOP=1 TB_TOY=/path")
    }

    private struct NobodyLocal: ClaudeAgentsReading { func sessions() -> [LiveSession]? { [] } }

    func testNewAgentThenAReplyThenTheAgentsWordsAreTheLatestTurn() async throws {
        let toy = ProcessInfo.processInfo.environment["TB_TOY"]!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(url: dir.appendingPathComponent("queue.sqlite"))
        let spool = dir.appendingPathComponent("spool.jsonl")
        let noConfig = dir.appendingPathComponent("hq.json")

        // The provider, built the way AgentProviders.registry builds it.
        let entry = ACPCatalog.published.first { $0.id == "opencode" }!
        guard let command = ACPCatalog.resolve(entry) else { return XCTFail("opencode not installed") }
        let transport = ACPProcessTransport(command: command, cwd: toy)
        let provider = ACPProvider(
            id: "opencode", client: ACPClient(transport: transport), cwd: toy,
            start: { try transport.start() },
            ledger: ProviderLedger(url: dir.appendingPathComponent("agents-used.json")),
            open: { entry.openLine(session: $0, binary: command[0]) })
        let registry = AgentProviderRegistry([provider], spawnable: ["opencode"])
        let poller = AgentPoller(registry: registry)
        poller.registryConfig = noConfig
        poller.trace = { print("LOOP poller: \($0)") }
        // Exactly what main.swift does on onEvents.
        poller.onEvents = { events in
            let snapshot = poller.snapshot
            let lines = events.flatMap { RemoteSpool.lines(for: $0, agent: snapshot.agent($0.session)) }
            if !lines.isEmpty { RemoteSpool.append(lines, to: spool) }
        }
        poller.start()
        defer { poller.stop() }

        let coordinator = Coordinator(
            store: store,
            remoteTransport: RemoteDispatchTransport(
                registry: registry,
                agent: { poller.snapshot.agent($0) },
                pending: { poller.snapshot.requests[$0] }),
            isRemote: { poller.snapshot.agent($0) != nil },
            enrolment: EnrolmentRegistry(url: dir.appendingPathComponent("enrolled.json")),
            agents: NobodyLocal(),
            sweep: SessionSweep(),
            readinessGrace: 0)

        // 1. New Agent: start, greeting recorded under the agent's id.
        let id = try await provider.start(Brief(prompt: ""))
        let workspace = (toy as NSString).lastPathComponent
        XCTAssertNotNil(try LaunchGreeting.record(sessionId: id, directory: toy,
                                                  line: "How should we get started?", store: store))
        for _ in 0..<40 where poller.snapshot.agent(id) == nil { try await Task.sleep(for: .milliseconds(50)) }
        let fresh = try XCTUnwrap(poller.snapshot.agent(id), "the poller never heard the agent appear")
        XCTAssertEqual(fresh.state, .inputRequired, "a fresh agent is your turn")
        XCTAssertEqual(try coordinator.waiting().map(\.sessionId), [id],
                       "waiting for you, with no process on this Mac")

        // 2. The reply, the way the panel frames it, dispatched through the coordinator.
        let said = "Reply with exactly the two words PING PONG and nothing else. Do not use any tool."
        let utterance = Utterance(status: .ready,
                                  transcriptText: "[assistant]: How should we get started?\n\n[user]: \(said)",
                                  targetSessionId: id)
        try store.update(utterance: utterance)
        let outcome = try await coordinator.confirmAndSend(utteranceId: utterance.id)
        guard case .dispatched = outcome else { return XCTFail("dispatch was \(outcome)") }

        // 3. The turn ends; the drainer (on its own beat in the app) lands the lines.
        let drainer = SpoolDrainer(store: store, spoolURL: spool)
        var latest: WaitingSession?
        for _ in 0..<600 {
            _ = try drainer.drain()
            latest = try store.latestStop(for: id)
            if latest?.lastAssistantMessage?.contains("PONG") == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let words = try XCTUnwrap(latest?.lastAssistantMessage, "no words arrived within 60 s")
        XCTAssertTrue(words.contains("PONG"), "the latest turn is \(words.prefix(80)), not the agent's words")
        XCTAssertEqual(poller.snapshot.agent(id)?.state, .completed)
        XCTAssertEqual(try coordinator.waiting().map(\.sessionId), [id], "still yours after the turn")

        // 4. The row: named, its own harness, a door.
        let rows = GridAssembler.rows(GridAssembler.RowInputs(
            waiting: try store.waitingSessions(), known: try store.allKnownSessions(),
            discovered: [], liveById: [:], boundaries: [:],
            switchedOff: [], switchedOn: [],
            evidence: { _, _ in nil }, isHeadless: { _ in false }, family: { [$0] },
            supersedesWaiting: { _, _ in false }, isInFlight: { _ in false },
            remote: .init(agents: poller.snapshot.agents, requests: poller.snapshot.requests,
                          unread: [id], unreachable: poller.snapshot.unreachable))).rows
        let row = try XCTUnwrap(rows.first { $0.id == id }, "no row for the agent")
        XCTAssertEqual(row.harness, "opencode")
        XCTAssertNotEqual(row.name, SessionRow.shortId(id), "a hash is not a name")
        XCTAssertFalse(row.name.hasPrefix("[assistant]"), "the framing is not a name")
        XCTAssertTrue(row.name == workspace || row.name.hasPrefix("Reply with exactly") || !row.name.isEmpty)
        guard case .shell(let open, let directory) = row.door else { return XCTFail("door is \(row.door)") }
        XCTAssertTrue(open.contains("--session") && open.contains("ses_"), open)
        XCTAssertEqual(directory, toy)
        // Unread: a tap reads the answer. Heard: a tap opens OpenCode's own screen.
        XCTAssertEqual(SessionRow.action(for: row), .announce, "the answer comes before the door")
        let heard = SessionRow(id: row.id, name: row.name, aux: row.aux, lamp: row.lamp,
                               read: .none, harness: row.harness, door: row.door)
        XCTAssertEqual(SessionRow.action(for: heard), .openShell(open, directory: toy))
        print("LOOP: row name=\(row.name) lamp=\(row.lamp) words=\(words.prefix(60))")

        // 5. Read state: the grid's unread set comes from the waiting list, which
        // joins the heard cursor. Hearing the turn clears it.
        func unread() throws -> Set<String> {
            Set(try coordinator.waiting().filter { !$0.heard }.map(\.sessionId))
        }
        XCTAssertTrue(try unread().contains(id), "unread before it is heard")
        try store.advanceCursor(sessionId: id, heardThrough: latest!.latestId)
        XCTAssertFalse(try unread().contains(id), "heard clears the read state")
        XCTAssertEqual(try store.firstUtteranceText(to: id).map(HeardContext.spokenPart), said,
                       "the opening the summary asks with")
        let spooled = try XCTUnwrap(latest?.cwd)
        XCTAssertEqual(spooled, toy, "the event carries the agent's real directory")

        // 6. End Agent: gone from the snapshot, and not adopted by a fresh provider.
        await poller.end(id)
        XCTAssertNil(poller.snapshot.agent(id))
        XCTAssertFalse(try coordinator.waiting().map(\.sessionId).contains(id),
                       "no longer live once ended")
    }
}
