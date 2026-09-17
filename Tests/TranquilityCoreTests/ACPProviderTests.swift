import XCTest
@testable import TranquilityCore

private final class ScriptedPipe: ACPTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "scripted-pipe")
    private var continuation: AsyncStream<Data>.Continuation?
    private var _written: [String] = []
    var written: [String] { queue.sync { _written } }
    var answers: [String: String] = [
        "initialize": #"{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}"#,
        "session/new": #"{"sessionId":"ses_live"}"#,
        "session/prompt": #"{"stopReason":"end_turn"}"#,
        "session/cancel": #"{}"#,
    ]

    /// Notifications the agent sends BEFORE answering a method, the way
    /// `session/load` replays history before it returns.
    var before: [String: [String]] = [:]
    var spawns = 0
    /// The methods called, in order, read from the JSON rather than matched
    /// as text: key order in a serialized object is not a contract.
    var methods: [String] {
        written.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["method"] as? String
        }
    }
    func params(of method: String) -> [[String: Any]] {
        written.compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["method"] as? String == method else { return nil }
            return object["params"] as? [String: Any]
        }
    }

    func write(_ line: Data) async throws {
        queue.sync { _written.append(String(decoding: line, as: UTF8.self)) }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? Int else { return }
        guard let method = object["method"] as? String else { return }  // our response, not a call
        guard let result = answers[method] else { return }
        for notification in before[method] ?? [] { emit(notification) }
        emit(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
    }
    func emit(_ line: String) { continuation?.yield(Data(line.utf8)) }
    func lines() -> AsyncStream<Data> { AsyncStream { self.continuation = $0 } }
    func close() async { continuation?.finish() }
}

final class ACPProviderTests: XCTestCase {

    private func connected() async throws -> (ACPProvider, ScriptedPipe) {
        let pipe = ScriptedPipe()
        let provider = ACPProvider(id: "opencode", client: ACPClient(transport: pipe), cwd: "/tmp")
        await provider.openEventStream()
        try await provider.connect()
        return (provider, pipe)
    }

    /// Collect up to `upTo` events, but **give up on a clock**.
    ///
    /// The first version of this waited for a count with a `Task` that slept
    /// alongside and cancelled nothing, so a test expecting two events and
    /// getting one hung the whole suite rather than failing. A drain that
    /// cannot end is not a test helper, it is a deadlock with a nice name.
    private func drain(_ provider: ACPProvider, upTo: Int,
                       within: Duration = .seconds(2)) async -> [AgentEvent] {
        guard let stream = provider.changes() else { return [] }
        let collected = Collector()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream {
                    if await collected.add(event) >= upTo { return }
                }
            }
            group.addTask { try? await Task.sleep(for: within) }
            await group.next()
            group.cancelAll()
        }
        return await collected.events
    }

    private actor Collector {
        private(set) var events: [AgentEvent] = []
        func add(_ event: AgentEvent) -> Int { events.append(event); return events.count }
    }

    private func ledger() -> ProviderLedger {
        ProviderLedger(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-ledger-\(UUID().uuidString).json"))
    }

    /// A provider the way the registry builds it: no process until something
    /// asks for one, and `spawns` counts the asks.
    private func registered(ledger: ProviderLedger, listing: String? = nil)
        -> (ACPProvider, ScriptedPipe) {
        let pipe = ScriptedPipe()
        if let listing {
            pipe.answers["initialize"] = #"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"list":{},"resume":{}}}}"#
            pipe.answers["session/list"] = listing
            pipe.answers["session/load"] = "{}"
        }
        let provider = ACPProvider(id: "opencode", client: ACPClient(transport: pipe),
                                   cwd: "/Users/someone/Documents/tranquility-base",
                                   start: { pipe.spawns += 1 }, ledger: ledger)
        return (provider, pipe)
    }

    // MARK: - #470: a started agent survives a relaunch

    /// A provider this Mac has never started an agent on stays a free registry
    /// entry: the poller's seed asks, and it answers nothing without spawning.
    func testAProviderNeverUsedHereIsNotSpawnedToBeListed() async throws {
        let (provider, pipe) = registered(ledger: ledger())
        let found = try await provider.mine()
        XCTAssertEqual(found, [])
        XCTAssertEqual(pipe.spawns, 0)
    }

    /// Starting an agent marks the ledger, and a fresh provider on the same
    /// ledger (the next launch) spawns, lists, and has the session back.
    func testAProviderUsedHereSpawnsAtSeedAndAdoptsWhatItStarted() async throws {
        let ledger = ledger()
        let (first, _) = registered(ledger: ledger, listing: #"{"sessions":[]}"#)
        _ = try await first.start(Brief(prompt: ""))
        XCTAssertTrue(ledger.used("opencode"))

        let (relaunched, pipe) = registered(
            ledger: ledger,
            listing: #"{"sessions":[{"sessionId":"ses_live","title":"Three planet paragraphs","cwd":"/Users/someone/Documents/tranquility-base","updatedAt":"2026-09-15T20:15:04.847Z"},{"sessionId":"ses_empty","title":"New session - 2026-09-15T20:15:04.847Z","cwd":"/Users/someone/Documents/tranquility-base"}]}"#)
        let found = try await relaunched.mine()
        XCTAssertEqual(pipe.spawns, 1)
        XCTAssertEqual(found.map(\.providerID), ["ses_live"])
        XCTAssertEqual(found.first?.title, "Three planet paragraphs")
        XCTAssertEqual(found.first?.repository, "tranquility-base",
                       "the row falls back to the agent's place, never its hash")
        XCTAssertFalse(found.contains { $0.providerID == "ses_empty" },
                       "a session nobody ever spoke to is not adopted")
        XCTAssertEqual(pipe.params(of: "session/list").first?["cwd"] as? String,
                       "/Users/someone/Documents/tranquility-base",
                       "the list is filtered to the workspace")
    }

    /// An adopted session is loaded before it is spoken to, and the history
    /// the load replays is not announced as new.
    func testAnAdoptedSessionIsLoadedBeforeItsFirstPromptAndTheReplayIsSilent() async throws {
        let ledger = ledger()
        ledger.mark("opencode")
        let (provider, pipe) = registered(
            ledger: ledger,
            listing: #"{"sessions":[{"sessionId":"ses_live","title":"Three planet paragraphs","cwd":"/x","updatedAt":"2026-09-15T20:15:04.847Z"}]}"#)
        pipe.before["session/load"] = [
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_live","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"yesterday's answer"}}}}"#,
        ]
        let found = try await provider.mine()
        let id = try XCTUnwrap(found.first?.id)

        let outcome = try await provider.send("and today?", to: id)
        XCTAssertEqual(outcome, .accepted)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pipe.methods.filter { $0.hasPrefix("session/") },
                       ["session/list", "session/load", "session/prompt", "session/list"],
                       "loaded once, prompted, then re-listed for the model's title")
        let transcript = try await provider.transcript(id)
        XCTAssertTrue(transcript.isEmpty,
                      "replayed history is not something the agent just said")
        let events = await drain(provider, upTo: 20, within: .milliseconds(300))
        XCTAssertFalse(events.contains { if case .said = $0.kind { return true } else { return false } },
                       "nothing replayed was announced")
    }

    /// End Agent: forgotten here, and not adopted again at the next launch.
    func testAForgottenSessionIsGoneAndStaysGoneAcrossALaunch() async throws {
        let ledger = ledger()
        ledger.mark("opencode")
        let listing = #"{"sessions":[{"sessionId":"ses_live","title":"Three planet paragraphs","cwd":"/x"}]}"#
        let (provider, pipe) = registered(ledger: ledger, listing: listing)
        let found = try await provider.mine()
        let id = try XCTUnwrap(found.first?.id)
        await provider.forget(id)
        let after = try await provider.mine()
        XCTAssertEqual(after.map(\.providerID), [], "the list still has it; this provider does not")
        XCTAssertTrue(pipe.methods.contains("session/cancel"))
        let (relaunched, _) = registered(ledger: ledger, listing: listing)
        let next = try await relaunched.mine()
        XCTAssertEqual(next.map(\.providerID), [], "End Agent survives a relaunch, or the row refuses to end")
    }

    /// A second prompt does not load again.
    func testASessionIsLoadedOnce() async throws {
        let ledger = ledger()
        ledger.mark("opencode")
        let (provider, pipe) = registered(
            ledger: ledger,
            listing: #"{"sessions":[{"sessionId":"ses_live","title":"t","cwd":"/x"}]}"#)
        let found = try await provider.mine()
        let id = try XCTUnwrap(found.first?.id)
        _ = try await provider.send("one", to: id)
        _ = try await provider.send("two", to: id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pipe.methods.filter { $0 == "session/load" }.count, 1)
    }

    /// An agent started with nothing to do is waiting for you: green, not
    /// blue. It shipped as `.submitted` and the row said "working" (#470).
    func testAFreshAgentWithNoBriefIsYourTurn() async throws {
        let (provider, _) = registered(ledger: ledger())
        let id = try await provider.start(Brief(prompt: ""))
        let session = try await provider.refine(id)
        XCTAssertEqual(session.state, .inputRequired)
        XCTAssertEqual(AgentPresentation.bucket(state: session.state, hasPendingRequest: false), .yours)
        XCTAssertEqual(session.repository, "tranquility-base")
        XCTAssertEqual(session.title, "")
    }

    /// The first thing said names the row until the model does.
    func testTheFirstMessageTitlesAnUntitledSession() async throws {
        let (provider, _) = registered(ledger: ledger())
        let id = try await provider.start(Brief(prompt: ""))
        _ = try await provider.send("Add a docstring to greet()\nand nothing else", to: id)
        try await Task.sleep(for: .milliseconds(100))
        let session = try await provider.refine(id)
        XCTAssertEqual(session.title, "Add a docstring to greet()")
    }

    /// OpenCode answers `session/new` with `available_commands_update`;
    /// that is configuration, not a turn, and must not turn a fresh agent blue.
    func testConfigurationUpdatesAreNotWork() async throws {
        let (provider, pipe) = registered(ledger: ledger())
        let id = try await provider.start(Brief(prompt: ""))
        pipe.emit(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_live","update":{"sessionUpdate":"available_commands_update","availableCommands":[]}}}"#)
        pipe.emit(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_live","update":{"sessionUpdate":"current_mode_update","currentModeId":"build"}}}"#)
        try await Task.sleep(for: .milliseconds(150))
        let session = try await provider.refine(id)
        XCTAssertEqual(session.state, .inputRequired, "configuration is not activity")
    }

    /// What was said picks the option; the id goes back on the wire.
    func testSpeechPicksThePermissionOption() {
        let request = PendingRequest(id: "p", session: "s", asked: "Run it?", options: [
            .init(id: "allow", label: "Allow", kind: .allowOnce),
            .init(id: "allow_always", label: "Always allow", kind: .allowAlways),
            .init(id: "reject", label: "Reject", kind: .rejectOnce),
        ])
        XCTAssertEqual(request.option(chosenBy: "yes")?.id, "allow")
        XCTAssertEqual(request.option(chosenBy: "Yeah, go ahead.")?.id, "allow")
        XCTAssertEqual(request.option(chosenBy: "yes, and always")?.id, "allow_always")
        XCTAssertEqual(request.option(chosenBy: "no")?.id, "reject")
        XCTAssertEqual(request.option(chosenBy: "don't do that")?.id, "reject")
        XCTAssertEqual(request.option(chosenBy: "Always allow")?.id, "allow_always", "a label verbatim")
        XCTAssertEqual(request.option(chosenBy: "reject")?.id, "reject", "an id verbatim")
        XCTAssertNil(request.option(chosenBy: "what is this for?"), "a question is not a choice")
        // The agent's own question, with its own labels.
        let scope = PendingRequest(id: "q", session: "s", asked: "How deep should this research run?", options: [
            .init(id: "Thorough (Recommended)", label: "Thorough (Recommended)"),
            .init(id: "Standard", label: "Standard"),
            .init(id: "Quick", label: "Quick"),
        ])
        XCTAssertEqual(scope.option(chosenBy: "thorough")?.id, "Thorough (Recommended)")
        XCTAssertEqual(scope.option(chosenBy: "let's go standard")?.id, "Standard")
        XCTAssertEqual(scope.option(chosenBy: "quick please")?.id, "Quick")
        XCTAssertNil(scope.option(chosenBy: "yes"), "yes chooses nothing among named options")
    }

    func testAHeadlineIsOneLineOfARowsWidth() {
        XCTAssertEqual(ACPProvider.headline("  short  "), "short")
        XCTAssertEqual(ACPProvider.headline(String(repeating: "x", count: 80)).count, 60)
        XCTAssertEqual(ACPProvider.headline("first\nsecond"), "first")
        XCTAssertEqual(ACPProvider.headline("[assistant]: How should we get started?\n\n[user]: Tell me about recent work."),
                       "Tell me about recent work.",
                       "the panel's framing is not the title; the user's words are")
    }

    /// **Capabilities come off the wire, not out of the catalog.** Before the
    /// handshake the provider claims nothing, which is the honest state and
    /// the one a catalog-declared table cannot represent.
    func testCapabilitiesAreEmptyUntilTheAgentHasSpoken() async throws {
        let pipe = ScriptedPipe()
        let provider = ACPProvider(id: "opencode", client: ACPClient(transport: pipe), cwd: "/tmp")
        XCTAssertFalse(provider.can.canSend, "nothing is claimed before the handshake")
        try await provider.connect()
        XCTAssertTrue(provider.can.canSend)
        XCTAssertTrue(provider.can.canAnswer)
        XCTAssertFalse(provider.can.sendWhileWorking,
                       "ACP's prompt turn is request/response; the gap is surfaced, not hidden")
    }

    /// ACP PUSHES. `changes()` returning a stream is the declaration, and it
    /// is one the poller has to branch on to work at all, so it cannot rot.
    func testTheProviderStreamsRatherThanWaitingToBePolled() async throws {
        let (provider, _) = try await connected()
        XCTAssertNotNil(provider.changes(), "an ACP agent is a push provider")
    }

    /// A permission prompt is the honest blocking request this app could not
    /// see before ACP. It must arrive as `.asks`, carrying the agent's own
    /// option ids, because answering with a LABEL is rejected by the agent and
    /// the row would hold its lamp for ever.
    func testAPermissionPromptBecomesABlockingRequestCarryingItsOptionIds() async throws {
        let (provider, pipe) = try await connected()
        pipe.emit("""
        {"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":\
        {"sessionId":"ses_live","toolCall":{"title":"Run `rm -rf build`"},\
        "options":[{"optionId":"allow-1","name":"Allow once","kind":"allow_once"},\
        {"optionId":"reject-1","name":"Reject","kind":"reject_once"}]}}
        """)
        let events = await drain(provider, upTo: 2)
        guard let asks = events.compactMap({ event -> PendingRequest? in
            if case .asks(let request) = event.kind { return request }
            return nil
        }).first else { return XCTFail("no blocking request: \(events.map(\.kind))") }

        XCTAssertEqual(asks.questions.first?.asked, "Run `rm -rf build`")
        XCTAssertEqual(asks.questions.first?.options.map(\.id), ["allow-1", "reject-1"])
        XCTAssertEqual(asks.questions.first?.options.map(\.kind), [.allowOnce, .rejectOnce])
    }

    /// And answering it sends the OPTION ID back on the agent's own JSON-RPC
    /// id, as a response. A new request would be ignored and the agent would
    /// wait for ever.
    func testAnsweringRepliesOnTheAgentsOwnRequestIdWithTheOptionId() async throws {
        let (provider, pipe) = try await connected()
        pipe.emit("""
        {"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":\
        {"sessionId":"ses_live","toolCall":{"title":"ok?"},\
        "options":[{"optionId":"allow-1","name":"Allow","kind":"allow_once"}]}}
        """)
        _ = await drain(provider, upTo: 2)
        guard let request = try await provider.request(
            AgentSession.id("ses_live", provider: "opencode"))
        else { return XCTFail("the request was not retained for answering") }

        let outcome = try await provider.respond(to: request, with: Response(answers: [["allow-1"]]))
        XCTAssertEqual(outcome, .accepted)

        let reply = pipe.written.last ?? ""
        XCTAssertTrue(reply.contains("\"id\":42"), "answered on the agent's id: \(reply)")
        XCTAssertTrue(reply.contains("allow-1"), "carries the option id: \(reply)")
        XCTAssertFalse(reply.contains("\"method\""), "a response, not a new request")
    }

    /// An option with no id is DROPPED rather than sent back as an empty
    /// string the agent would reject.
    func testAnOptionWithNoIdIsDroppedRatherThanSentBackEmpty() {
        // One line, deliberately. A `\` inside a RAW string is a literal
        // backslash, not a continuation, so the first version of this fixture
        // was invalid JSON that decoded to nil and "proved" the drop.
        let raw = Data(#"{"sessionId":"s","toolCall":{"title":"t"},"options":[{"name":"No id here"},{"optionId":"good","name":"Fine","kind":"allow_once"}]}"#.utf8)
        let permission = try? JSONDecoder().decode(ACPPermission.self, from: raw)
        let pending = permission?.pending(session: "s")
        XCTAssertEqual(pending?.questions.first?.options.map(\.id), ["good"])
    }

    /// Anything at all from the agent means it is working, so an update this
    /// app cannot name is still evidence rather than a silent drop.
    func testAnUnrecognisedUpdateStillReportsTheAgentAsWorking() async throws {
        let (provider, pipe) = try await connected()
        pipe.emit(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_x","update":{"sessionUpdate":"something_invented_next_release"}}}"#)
        let events = await drain(provider, upTo: 1)
        guard case .appeared(let session)? = events.first?.kind
        else { return XCTFail("\(events.map(\.kind))") }
        XCTAssertEqual(session.state, .working)
    }

    /// A message chunk becomes a Turn, which is what reaches the spool line.
    /// Chunks accumulate; the turn's words are said ONCE, when it ends. A
    /// `.said` per chunk was a spool line per chunk, and every spool line is
    /// a turn the panel announces.
    func testATurnsChunksAreSaidOnceWhenTheTurnEnds() async throws {
        let (provider, pipe) = try await connected()
        pipe.before["session/prompt"] = [
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_live","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"working "}}}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_live","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"on it"}}}}"#,
        ]
        let id = try await provider.start(Brief(prompt: ""))
        let outcome = try await provider.send("go", to: id)
        XCTAssertEqual(outcome, .accepted, "accepted when the prompt is taken, not when the turn ends")
        let events = await drain(provider, upTo: 12, within: .milliseconds(400))
        let said = events.compactMap { event -> Turn? in
            if case .said(let turn) = event.kind { return turn }
            return nil
        }
        XCTAssertEqual(said.map(\.text), ["working on it"])
        XCTAssertEqual(said.first?.role, .agent)
        // The ending precedes the words, so the session's latest line carries them.
        let kinds = events.map { event -> String in
            switch event.kind {
            case .said: return "said"
            case .changed(let s) where s.state == .completed: return "completed"
            default: return "other"
            }
        }
        XCTAssertLessThan(try XCTUnwrap(kinds.firstIndex(of: "completed")),
                          try XCTUnwrap(kinds.firstIndex(of: "said")))
        let session = try await provider.refine(id)
        XCTAssertEqual(session.state, .completed)
    }
}

// MARK: - The shared suite, applied to a real ACP provider

/// The same suite every other provider answers to, driven against an ACP
/// provider on a scripted pipe. The point of a conformance suite is that a new
/// provider family joins it rather than getting its own rules, and ACP is the
/// third family after HTTP-polled and HTTP-streamed.
final class ACPConformanceTests: XCTestCase {

    func testAnACPProviderConformsToTheSharedSuite() async throws {
        let pipe = ScriptedPipeForConformance()
        let provider = ACPProvider(id: "acp-test", client: ACPClient(transport: pipe), cwd: "/tmp")
        await provider.openEventStream()
        try await provider.connect()
        try await AgentProviderConformance.run(provider, egress: false)
    }
}

/// Separate from `ScriptedPipe` because the conformance run reaches parts the
/// unit tests do not, and a fixture shared between them would drift toward
/// whichever needed more.
private final class ScriptedPipeForConformance: ACPTransport, @unchecked Sendable {
    private var continuation: AsyncStream<Data>.Continuation?
    func push(_ line: String) { continuation?.yield(Data(line.utf8)) }
    func write(_ line: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String
        else { return }
        // **Strict about `params`, on purpose.** A live `opencode acp` answers
        // `session/list` with nothing at all when `params` is absent, and the
        // first version of this fake answered regardless — so the fixture went
        // green while the real agent returned zero sessions. A fake more
        // permissive than the thing it stands in for cannot fail for the
        // reason production fails.
        guard object["params"] != nil else { return }
        // Declares `list` AND answers it, because those are two different
        // claims and the suite is entitled to check the second one. A fixture
        // that declared a capability it did not implement would pass a suite
        // written to catch exactly that.
        let results = [
            "initialize": #"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"list":{},"resume":{}}}}"#,
            "session/list": #"{"sessions":[{"sessionId":"ses_existing","title":"Something from before","updatedAt":"2026-09-14T20:41:44.422Z"}]}"#,
            "session/new": #"{"sessionId":"ses_conf"}"#,
            "session/prompt": #"{"stopReason":"end_turn"}"#,
            "session/cancel": #"{}"#,
        ]
        guard let result = results[method] else { return }
        continuation?.yield(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8))
    }
    func lines() -> AsyncStream<Data> { AsyncStream { self.continuation = $0 } }
    func close() async { continuation?.finish() }
}

extension ACPConformanceTests {

    /// **The catch-up, as its own assertion.** A push provider only hears what
    /// happens next, so a session that existed before the client attached is
    /// invisible without `session/list`. That exact defect shipped once, over
    /// HTTP, and was found on a live server rather than in a test.
    func testSessionsThatExistedBeforeWeAttachedAreFound() async throws {
        let pipe = ScriptedPipeForConformance()
        let provider = ACPProvider(id: "acp-test", client: ACPClient(transport: pipe), cwd: "/tmp")
        await provider.openEventStream()
        try await provider.connect()

        let found = try await provider.mine()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.providerID, "ses_existing")
        XCTAssertEqual(found.first?.title, "Something from before")
        XCTAssertEqual(found.first?.state, .completed,
                       "a listed session has finished its turn, which is green, not amber")
        XCTAssertGreaterThan(found.first?.updatedAt ?? .distantPast,
                             Date(timeIntervalSince1970: 1),
                             "a fractional-second stamp parsed, rather than sorting to 1970")
    }

    /// And a session the provider is already streaming keeps what streaming
    /// taught it: a list that overwrote `.working` with `.completed` would put
    /// a green lamp on an agent mid-turn.
    func testAListDoesNotOverwriteWhatStreamingAlreadyKnows() async throws {
        let pipe = ScriptedPipeForConformance()
        let provider = ACPProvider(id: "acp-test", client: ACPClient(transport: pipe), cwd: "/tmp")
        await provider.openEventStream()
        try await provider.connect()
        pipe.push(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_existing","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}"#)
        try await Task.sleep(for: .milliseconds(150))

        let found = try await provider.mine()
        XCTAssertEqual(found.first?.state, .working,
                       "the stream outranks the list for a session it is watching")
    }
}
