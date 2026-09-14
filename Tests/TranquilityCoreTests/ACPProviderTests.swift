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

    func write(_ line: Data) async throws {
        queue.sync { _written.append(String(decoding: line, as: UTF8.self)) }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? Int else { return }
        guard let method = object["method"] as? String else { return }  // our response, not a call
        guard let result = answers[method] else { return }
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
    func testAMessageChunkBecomesSomethingTheAgentSaid() async throws {
        let (provider, pipe) = try await connected()
        pipe.emit(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_x","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"working on it"}}}}"#)
        let events = await drain(provider, upTo: 2)
        let said = events.compactMap { event -> Turn? in
            if case .said(let turn) = event.kind { return turn }
            return nil
        }
        XCTAssertEqual(said.first?.text, "working on it")
        XCTAssertEqual(said.first?.role, .agent)
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
