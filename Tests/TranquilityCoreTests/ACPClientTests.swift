import XCTest
@testable import TranquilityCore

/// A scripted agent on a pipe. No process, no install, so CI exercises the
/// whole protocol on a machine that has none of these agents.
private final class ScriptedAgent: ACPTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "scripted-agent")
    private var continuation: AsyncStream<Data>.Continuation?
    private var _written: [String] = []
    var written: [String] { queue.sync { _written } }
    /// method -> the result object to answer with.
    var answers: [String: String] = [:]
    var closed = false

    func write(_ line: Data) async throws {
        let text = String(decoding: line, as: UTF8.self)
        queue.sync { _written.append(text) }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String
        else { return }
        guard let result = answers[method] else { return }
        emit(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
    }

    func emit(_ line: String) { continuation?.yield(Data(line.utf8)) }
    func endOfPipe() { continuation?.finish() }

    func lines() -> AsyncStream<Data> {
        AsyncStream { self.continuation = $0 }
    }
    func close() async { closed = true; continuation?.finish() }
}

final class ACPClientTests: XCTestCase {

    private func client(_ agent: ScriptedAgent) async -> ACPClient {
        let client = ACPClient(transport: agent)
        await client.start()
        return client
    }

    /// The live handshake, byte for byte off `opencode acp` 1.18.30 on
    /// 14 Sep 2026. Recorded rather than invented, so a change in the agent's
    /// shape shows up here as a failure rather than as an idle grid.
    private let liveInitialize = """
    {"protocolVersion":1,"agentCapabilities":{"loadSession":true,\
    "promptCapabilities":{"embeddedContext":true,"image":true},\
    "sessionCapabilities":{"close":{},"fork":{},"list":{},"resume":{}}},\
    "authMethods":[{"description":"Run `opencode auth login` in the terminal",\
    "name":"Login with opencode","id":"opencode-login"}],\
    "agentInfo":{"name":"OpenCode","version":"1.18.30"}}
    """

    // MARK: - Framing

    /// **Newline-delimited JSON, not `Content-Length` headers.** The single
    /// most likely thing to get wrong, because every sibling protocol in this
    /// lineage frames with headers, and getting it wrong looks like an agent
    /// that never answers.
    func testEveryMessageIsOneLineWithNoHeaders() async throws {
        let agent = ScriptedAgent()
        agent.answers["initialize"] = liveInitialize
        let client = await self.client(agent)
        _ = try await client.initialize()

        let sent = agent.written.first ?? ""
        XCTAssertFalse(sent.contains("Content-Length"), "ACP does not frame with headers")
        XCTAssertFalse(sent.dropLast().contains("\n"), "one message is one line")
        XCTAssertTrue(sent.hasPrefix("{"), "and the line is bare JSON")
    }

    // MARK: - The handshake is the capability declaration

    /// The economic argument of this whole client, as a test: a catalog entry
    /// states a NAME and a COMMAND, and the agent states what it can do. A
    /// capability table in the catalog would go stale on the vendor's next
    /// release and nothing would notice.
    func testCapabilitiesComeFromTheAgentAndNotFromUs() async throws {
        let agent = ScriptedAgent()
        agent.answers["initialize"] = liveInitialize
        let client = await self.client(agent)
        let shook = try await client.initialize()

        XCTAssertEqual(shook.agentInfo?.name, "OpenCode")
        XCTAssertEqual(shook.agentInfo?.version, "1.18.30")
        XCTAssertTrue(shook.agentCapabilities?.loadSession == true)
        XCTAssertTrue(shook.agentCapabilities?.promptCapabilities?.image == true)
    }

    /// Present-means-supported: the agent returns EMPTY OBJECTS, not booleans,
    /// so a decoder that expected `Bool` would read every one of them as
    /// absent and quietly report an agent that can do nothing.
    func testSessionCapabilitiesAreDeclaredByThePresenceOfTheKey() async throws {
        let agent = ScriptedAgent()
        agent.answers["initialize"] = liveInitialize
        let client = await self.client(agent)
        let caps = try await client.initialize().agentCapabilities?.sessionCapabilities
        XCTAssertTrue(caps?.list == true)
        XCTAssertTrue(caps?.resume == true)
        XCTAssertTrue(caps?.fork == true)
        XCTAssertTrue(caps?.close == true)
    }

    /// A version we do not speak is refused, not tolerated. Every payload shape
    /// below the handshake depends on it, so carrying on would mean decoding
    /// the next version's messages with this version's expectations and
    /// reporting the resulting nils as a calm agent.
    func testAProtocolVersionWeDoNotSpeakIsRefused() async throws {
        let agent = ScriptedAgent()
        agent.answers["initialize"] = #"{"protocolVersion":99}"#
        let client = await self.client(agent)
        do {
            _ = try await client.initialize()
            XCTFail("a version mismatch must not be tolerated")
        } catch let error as ACPClient.ClientError {
            XCTAssertEqual(error, .versionMismatch(theirs: 99, ours: 1))
        }
    }

    // MARK: - Survival

    /// Agents print banners, warnings and progress to stdout. A client that
    /// died on the first one would work only for the agents that happen to be
    /// quiet, which is not a property anybody checks before shipping a catalog
    /// entry.
    func testNonProtocolChatterOnStdoutIsIgnoredRatherThanFatal() async throws {
        let agent = ScriptedAgent()
        let client = await self.client(agent)
        agent.emit("Welcome to the agent!")
        agent.emit("")
        agent.emit("{not json at all")
        agent.answers["initialize"] = liveInitialize
        let shook = try await client.initialize()
        XCTAssertEqual(shook.protocolVersion, 1, "the banner did not kill the client")
    }

    /// **The pipe closing is an answer.** A request outstanding when the agent
    /// exits must fail with its reason rather than hang until its timeout;
    /// three minutes of a stalled await reads to the user as a working agent.
    func testTheAgentExitingFailsEveryOutstandingRequest() async throws {
        let agent = ScriptedAgent()
        let client = await self.client(agent)
        let asked = Task { try await client.request("session/prompt") }
        try await Task.sleep(for: .milliseconds(120))
        agent.endOfPipe()
        do {
            _ = try await asked.value
            XCTFail("a closed pipe must not resolve as success")
        } catch let error as ACPClient.ClientError {
            guard case .remote(_, let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("stdio closed"), message)
        }
    }

    // MARK: - A turn, and why it stopped

    /// `stopReason` decides the lamp, and **a refusal is not a finished turn.**
    /// The three-lamp ruling reserves amber for the unanticipated, and an agent
    /// that hit a token ceiling or declined the work has not finished anything
    /// the user would call finished.
    func testWhyATurnStoppedDecidesTheState() {
        func state(_ raw: String) -> AgentSessionState? {
            let line = Data(#"{"jsonrpc":"2.0","id":1,"result":{"stopReason":"\#(raw)"}}"#.utf8)
            return ACPWire.Message(line: line)?.result(ACPWire.PromptResult.self)?.state
        }
        XCTAssertEqual(state("end_turn"), .completed)
        XCTAssertEqual(state("cancelled"), .canceled)
        XCTAssertEqual(state("refusal"), .rejected)
        XCTAssertEqual(state("max_tokens"), .failed)
        XCTAssertEqual(state("max_turn_requests"), .failed)
    }

    /// A notification has a method and no id; a response has an id and no
    /// method; an agent's own request has both. Deciding which a line is IS the
    /// parse, and getting it wrong routes a permission prompt into the void.
    func testTheThreeEnvelopesAreToldApart() {
        func message(_ raw: String) -> ACPWire.Message? { ACPWire.Message(line: Data(raw.utf8)) }
        let notification = message(#"{"jsonrpc":"2.0","method":"session/update","params":{}}"#)
        XCTAssertTrue(notification?.isNotification == true)
        XCTAssertFalse(notification?.isAgentRequest == true)

        let response = message(#"{"jsonrpc":"2.0","id":7,"result":{}}"#)
        XCTAssertFalse(response?.isNotification == true)
        XCTAssertFalse(response?.isAgentRequest == true)

        let ask = message(
            #"{"jsonrpc":"2.0","id":8,"method":"session/request_permission","params":{}}"#)
        XCTAssertTrue(ask?.isAgentRequest == true)
        XCTAssertEqual(ask?.id, 8)
    }


    /// Measured against a live agent on 14 Sep: with `params` absent,
    /// `session/list` returns nothing at all — no result, no error, silence
    /// until the timeout. JSON-RPC 2.0 permits omitting it; this agent does
    /// not. Always sending it costs two bytes.
    func testEveryRequestCarriesAParamsMemberEvenWhenEmpty() async throws {
        let agent = ScriptedAgent()
        agent.answers["session/cancel"] = "{}"
        let client = ACPClient(transport: agent)
        await client.start()
        _ = try? await client.request("session/cancel")

        let sent = agent.written.last ?? ""
        let object = try? JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        XCTAssertNotNil(object?["params"],
                        "params must be present even when empty: \(sent)")
    }
}
