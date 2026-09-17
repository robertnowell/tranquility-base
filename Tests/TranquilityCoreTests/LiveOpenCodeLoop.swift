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

        // The provider, built the way AgentProviders.registry builds it: a
        // served OpenCode this test owns, on a port of its own.
        let entry = ACPCatalog.published.first { $0.id == "opencode" }!
        guard let command = ACPCatalog.resolve(entry) else { return XCTFail("opencode not installed") }
        let provider = ServedOpenCodeProvider(
            binary: command[0], directory: toy,
            ledger: ProviderLedger(url: dir.appendingPathComponent("agents-used.json")),
            hostsPanes: true)
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
        // Printed before rethrowing: XCTest on this toolchain reports a
        // thrown error at the site of the LAST throw it saw, including one
        // swallowed by `try?` (17 Sep: a missing TB_TOY read as a missing
        // ledger file at ProviderLedger.swift:63).
        let id: AgentSession.ID
        do { id = try await provider.start(Brief(prompt: "")) } catch { print("LOOP: start threw \(error)"); throw error }
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
        // 2b. While the turn runs the row is BLUE: the provider reports working
        // and the snapshot carries it. Robert, 15 Sep 5:20 PM, on a row that
        // stayed green through a whole turn: "the lamps are not working."
        var seenWorking = false
        for _ in 0..<100 {
            if let s = poller.snapshot.agent(id)?.state, s == .working || s == .submitted { seenWorking = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(seenWorking, "the snapshot never showed the agent working during its turn; state=\(String(describing: poller.snapshot.agent(id)?.state))")

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
        // The door is the pane the TUI has been attached in since `start`,
        // not a command to attach one now: a TUI attached after an ask never
        // shows it (17 Sep), so the screen has to exist before the question.
        guard case .pane(let paneName) = row.door else { return XCTFail("door is \(row.door)") }
        XCTAssertEqual(paneName, OpenCodePane.name(for: poller.snapshot.agent(id)!.providerID))
        XCTAssertTrue(OpenCodePane.isLive(raw: poller.snapshot.agent(id)!.providerID), "the TUI is attached in its pane")
        let screen = { (try? Tmux.run(["capture-pane", "-p", "-t", paneName], socket: Tmux.socketName).get()) ?? "" }
        XCTAssertTrue(screen().contains("PONG") || screen().contains("PING"),
                      "the pane shows the session's own conversation: \(screen().suffix(300))")
        // Unread: a tap reads the answer. HEARD: a tap reads it again (green
        // opens the card, everywhere; ruled 15 Sep and broken for remote rows
        // until 16 Sep, when a heard row was built as `.none`). Only a row
        // with no turn at all goes to the door.
        XCTAssertEqual(SessionRow.action(for: row), .announce, "the answer comes before the door")
        print("LOOP: row name=\(row.name) lamp=\(row.lamp) words=\(words.prefix(60))")

        // 5. Read state: the grid's unread set comes from the waiting list, which
        // joins the heard cursor. Hearing the turn clears it.
        func unread() throws -> Set<String> {
            Set(try coordinator.waiting().filter { !$0.heard }.map(\.sessionId))
        }
        XCTAssertTrue(try unread().contains(id), "unread before it is heard")
        try store.advanceCursor(sessionId: id, heardThrough: latest!.latestId)
        XCTAssertFalse(try unread().contains(id), "heard clears the read state")
        let heardRows = GridAssembler.rows(GridAssembler.RowInputs(
            waiting: try store.waitingSessions(), known: try store.allKnownSessions(),
            discovered: [], liveById: [:], boundaries: [:], switchedOff: [], switchedOn: [],
            evidence: { _, _ in nil }, isHeadless: { _ in false }, family: { [$0] },
            supersedesWaiting: { _, _ in false }, isInFlight: { _ in false },
            remote: .init(agents: poller.snapshot.agents, requests: poller.snapshot.requests,
                          unread: Set(try coordinator.waiting().filter { !$0.heard }.map(\.sessionId)),
                          unreachable: poller.snapshot.unreachable,
                          heard: Set(try coordinator.waiting().filter { $0.heard }.map(\.sessionId))))).rows
        let heardRow = try XCTUnwrap(heardRows.first { $0.id == id })
        XCTAssertEqual(heardRow.read, .opened)
        XCTAssertEqual(SessionRow.action(for: heardRow), .announce, "a heard green row still opens the card")
        let silent = SessionRow(id: row.id, name: row.name, aux: row.aux, lamp: row.lamp,
                                read: .none, harness: row.harness, door: row.door)
        XCTAssertEqual(SessionRow.action(for: silent), .attachPane(paneName), "only nothing-to-say goes to the door")
        XCTAssertEqual(try store.firstUtteranceText(to: id).map(HeardContext.spokenPart), said,
                       "the opening the summary asks with")
        let spooled = try XCTUnwrap(latest?.cwd)
        XCTAssertEqual(spooled, toy, "the event carries the agent's real directory")

        // 7. A permission: the agent asks, the question is a turn you hear,
        // "yes" answers it, and the turn finishes. Robert, 15 Sep 5:20 PM: a
        // green row with a question nobody spoke, whose tap opened a Terminal.
        let ask = Utterance(status: .ready,
                            transcriptText: "[assistant]: PING PONG. [user]: Run the shell command `mkdir -p /tmp/tb-permission-probe && date > /tmp/tb-permission-probe/stamp` with your bash tool, then reply with exactly the word DONE.",
                            targetSessionId: id)
        try store.update(utterance: ask)
        guard case .dispatched = try await coordinator.confirmAndSend(utteranceId: ask.id) else {
            return XCTFail("second dispatch refused")
        }
        var pending: PendingRequest?
        for _ in 0..<600 {
            _ = try drainer.drain()
            pending = poller.snapshot.requests[id]
            if pending != nil { break }
            if try store.latestStop(for: id)?.lastAssistantMessage?.contains("DONE") == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let pending {
            let asked = try XCTUnwrap(try store.latestStop(for: id)?.lastAssistantMessage)
            XCTAssertTrue(asked.hasPrefix("The agent is asking permission"), "the question is the latest turn: \(asked.prefix(80))")
            XCTAssertTrue(try unread().contains(id), "a question is unread until heard")
            XCTAssertEqual(poller.snapshot.agent(id)?.state, .inputRequired)
            // Held under the tool-call updates that keep arriving, and amber
            // on the grid with the tap bringing the decision back.
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(poller.snapshot.agent(id)?.state, .inputRequired, "a pending ask is not flipped back to working")
            let asking = GridAssembler.rows(GridAssembler.RowInputs(
                waiting: try store.waitingSessions(), known: try store.allKnownSessions(),
                discovered: [], liveById: [:], boundaries: [:], switchedOff: [], switchedOn: [],
                evidence: { _, _ in nil }, isHeadless: { _ in false }, family: { [$0] },
                supersedesWaiting: { _, _ in false }, isInFlight: { _ in false },
                remote: .init(agents: poller.snapshot.agents, requests: poller.snapshot.requests,
                              unread: [], unreachable: poller.snapshot.unreachable))).rows
            let askingRow = try XCTUnwrap(asking.first { $0.id == id })
            XCTAssertEqual(askingRow.lamp, .fault, "blocked on a permission is amber")
            XCTAssertEqual(SessionRow.action(for: askingRow), .attachPane(paneName),
                           "amber goes to the agent's own screen, where the question is")
            // And the question IS on that screen: the whole reason for the
            // pane. The TUI draws the tool's permission prompt with its
            // choices; a late attach draws nothing (measured 17 Sep).
            var shown = screen()
            for _ in 0..<20 where !shown.lowercased().contains("permission") && !shown.contains("mkdir") {
                try await Task.sleep(nanoseconds: 250_000_000); shown = screen()
            }
            XCTAssertTrue(shown.lowercased().contains("permission") || shown.contains("mkdir"),
                          "the pane does not show the ask: \(shown.suffix(400))")
            print("LOOP: pane screen at the ask:\n\(shown.suffix(600))")
            // Answered where Robert answers it: on the server, as the
            // attached terminal does with Enter. The app only WATCHES.
            var reply = URLRequest(url: provider.baseURL.appendingPathComponent("permission/\(pending.id)/reply"))
            reply.httpMethod = "POST"; reply.httpBody = Data(#"{"reply":"once"}"#.utf8)
            reply.setValue("application/json", forHTTPHeaderField: "content-type")
            let (_, replied) = try await URLSession.shared.data(for: reply)
            XCTAssertEqual((replied as? HTTPURLResponse)?.statusCode, 200)
            for _ in 0..<100 where poller.snapshot.requests[id] != nil { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertNil(poller.snapshot.requests[id], "the app saw the terminal's answer")
            var done: WaitingSession?
            for _ in 0..<600 {
                _ = try drainer.drain()
                done = try store.latestStop(for: id)
                if done?.lastAssistantMessage?.contains("DONE") == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(done?.lastAssistantMessage?.contains("DONE") == true,
                          "after the answer the turn finished: \(done?.lastAssistantMessage?.prefix(80) ?? "nil")")
            print("LOOP: permission asked=\(pending.asked.prefix(60)) answered; words=\(done?.lastAssistantMessage?.prefix(40) ?? "")")
        } else {
            print("LOOP: the agent ran the command without asking; leg skipped")
        }

        // 5b. A second app instance on the same server (a relaunch) adopts the
        // session WITH its last turn, keyed so the store keeps one copy, and
        // never lists a subagent.
        let second = ServedOpenCodeProvider(
            binary: command[0], directory: toy,
            ledger: ProviderLedger(url: dir.appendingPathComponent("agents-used.json")),
            port: provider.baseURL.port, hostsPanes: true)
        // A child session on the server, as a research subagent would leave.
        var mk = URLRequest(url: provider.baseURL.appendingPathComponent("session"))
        mk.httpMethod = "POST"; mk.setValue("application/json", forHTTPHeaderField: "content-type")
        mk.httpBody = Data("{\"parentID\":\"\(poller.snapshot.agent(id)!.providerID)\",\"title\":\"Verify a claim (@general subagent)\"}".utf8)
        _ = try await URLSession.shared.data(for: mk)
        // The model titles a session a few seconds after its first turn, and
        // an untitled session is not adopted (it reads as never spoken to).
        for _ in 0..<100 {
            let (data, _) = try await URLSession.shared.data(from: provider.baseURL.appendingPathComponent("session"))
            let titled = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?
                .contains { ($0["id"] as? String) == poller.snapshot.agent(id)?.providerID
                    && !(($0["title"] as? String) ?? "").hasPrefix("New session") } ?? false
            if titled { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let adopted = try await second.mine()
        // Every adopted session got a pane (the toy project keeps sessions
        // from earlier runs too); none of them outlives the test.
        defer { for a in adopted { OpenCodePane.kill(raw: a.providerID) } }
        XCTAssertTrue(adopted.contains { $0.id == id }, "the session comes back")
        XCTAssertFalse(adopted.contains { $0.title.contains("subagent") }, "a subagent is not a row")
        actor Bag { var items: [AgentEvent] = []; func add(_ e: AgentEvent) { items.append(e) } }
        let bag = Bag()
        if let stream = second.changes() {
            let collect = Task { for await e in stream { await bag.add(e) } }
            try await Task.sleep(for: .milliseconds(400)); collect.cancel()
        }
        let replay = await bag.items
        let saidAgain = replay.compactMap { e -> Turn? in if case .said(let t) = e.kind, e.session == id { return t } else { return nil } }
        XCTAssertGreaterThanOrEqual(saidAgain.count, 2, "adopted with its turns (PING PONG and DONE), oldest first, for the hub")
        XCTAssertEqual(saidAgain.last?.text.contains("DONE"), true, "the latest is what the announcer reads")
        if let again = saidAgain.first, let e = replay.first(where: { if case .said = $0.kind { return $0.session == id } else { return false } }) {
            let before = try store.allKnownSessions().count
            RemoteSpool.append(RemoteSpool.lines(for: e, agent: poller.snapshot.agent(id)), to: spool)
            _ = try drainer.drain()
            XCTAssertEqual(try store.allKnownSessions().count, before, "the same turn is one event, not two")
            _ = again
        }

        // 6. End Agent: gone from the snapshot, and not adopted by a fresh provider.
        let raw = poller.snapshot.agent(id)!.providerID
        XCTAssertTrue(OpenCodePane.isLive(raw: raw), "adoption re-hosted the pane")
        await poller.end(id)
        XCTAssertNil(poller.snapshot.agent(id))
        XCTAssertFalse(OpenCodePane.isLive(raw: raw), "End Agent takes its pane with it")
        XCTAssertFalse(try coordinator.waiting().map(\.sessionId).contains(id),
                       "no longer live once ended")
    }
}
