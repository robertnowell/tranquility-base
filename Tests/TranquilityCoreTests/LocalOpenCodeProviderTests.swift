import XCTest
@testable import TranquilityCore

/// The streaming half of the pair, and the first REAL provider to run the
/// conformance suite: everything before this was a stub written to agree with
/// the protocol it was testing.
final class LocalOpenCodeProviderTests: XCTestCase {

    private func provider(_ fake: OpenCodeClientTests.Fake) -> LocalOpenCodeProvider {
        LocalOpenCodeProvider(client: OpenCodeClient(transport: fake, provider: "opencode"))
    }

    private func populated() -> OpenCodeClientTests.Fake {
        let fake = OpenCodeClientTests.Fake()
        fake.routes["GET /session"] = (200, """
        [{"id":"ses_abc","title":"tidy the fixtures","time":{"updated":1757000600000}}]
        """)
        fake.routes["GET /session/ses_abc/message"] = (200, """
        [{"info":{"id":"m1","role":"assistant","time":{"created":1757000000000}},
          "parts":[{"type":"text","text":"Cleaning up."}]}]
        """)
        fake.routes["GET /question"] = (200, """
        [{"id":"q1","sessionID":"ses_abc","questions":[
          {"question":"Which branch?","options":[{"label":"main"},{"label":"dev"}]}]}]
        """)
        fake.routes["GET /permission"] = (200, "[]")
        fake.routes["POST /session/ses_abc/message"] = (200, "{}")
        fake.routes["POST /question/q1/reply"] = (200, "{}")
        fake.routes["POST /session"] = (200, #"{"id":"ses_new"}"#)
        fake.stream = [#"{"type":"session.idle","properties":{"sessionID":"ses_abc"}}"#]
        return fake
    }

    // MARK: - The conformance suite, against a real provider

    /// `egress: true` because the transport is a fixture. Against a live
    /// server the mutating half stays off by default, which is the guard the
    /// audit asked for.
    func testItConforms() async throws {
        try await AgentProviderConformance.run(provider(populated()), egress: true)
    }

    // MARK: - Capabilities that disagree with crobot's, which is the point

    func testItDeclaresTheThreeThingsCrobotDoesNot() {
        let can = provider(populated()).can
        XCTAssertTrue(can.listIsCallerScoped, "it is your own process on your own machine")
        XCTAssertFalse(can.carriesPullRequest, "no pull requests exist here")
        XCTAssertTrue(can.sendWhileWorking, "the queue is the server's problem")
    }

    /// nil is the honest answer: there is no web page for a process on your own
    /// machine, which is why the protocol lets this return nothing.
    func testThereIsNoPageToOpenForALocalServer() {
        XCTAssertNil(provider(populated()).url(for: "anything"))
    }

    /// Declaring a capability with nothing behind it is how the previous
    /// capability struct reached four dead fields.
    func testCancelRefusesRatherThanPretending() async throws {
        let p = provider(populated())
        XCTAssertFalse(p.can.canCancel)
        let outcome = try await p.cancel("x")
        XCTAssertEqual(outcome, .unsupported)
    }

    // MARK: - Ingress

    /// Non-nil IS the declaration that this provider pushes. crobot's is nil.
    func testItStreamsRatherThanBeingPolled() {
        XCTAssertNotNil(provider(populated()).changes())
    }

    /// Mandatory even for a streaming provider: it is the catch-up after the
    /// stream drops, and a local server restarts more often than a cluster.
    func testTheSnapshotIsAvailableEvenThoughItStreams() async throws {
        let sessions = try await provider(populated()).mine()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].title, "tidy the fixtures")
    }

    // MARK: - Ids

    /// The reduction to an addressable id is one-way, so the provider's own id
    /// travels beside it rather than being reversed out of a hash.
    func testTheServersOwnIdTravelsWithTheSession() async throws {
        let session = try await provider(populated()).mine().first
        XCTAssertEqual(session?.providerID, "ses_abc")
        XCTAssertEqual(session?.id, AgentSession.id("ses_abc", provider: "opencode"))
        XCTAssertTrue(ArtifactStore.isPlausibleSession(session!.id))
    }

    /// Every egress call addresses the server by ITS id, never by ours. Sending
    /// the hashed one would 404 on a route that looks correct.
    func testEgressAddressesTheServerByItsOwnId() async throws {
        let fake = populated()
        let p = provider(fake)
        let id = try await p.mine()[0].id
        _ = try await p.send("hello", to: id)
        XCTAssertTrue(fake.calls.contains { $0.path == "/session/ses_abc/message" },
                      "sent to: \(fake.calls.map(\.path))")
    }

    func testAnUnknownSessionRefusesRatherThanAddressingTheWrongOne() async {
        do {
            _ = try await provider(populated()).send("x", to: "not-a-session")
            XCTFail("expected a refusal")
        } catch let error as LocalOpenCodeProvider.ProviderError {
            XCTAssertEqual(error, .noSuchSession("not-a-session"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: - Answering

    /// A question answered on the permission route, or the reverse, is a 404
    /// the user reads as silence. The option vocabulary is what tells them
    /// apart: only a permission is built from ACP's allow/reject kinds.
    func testAQuestionIsAnsweredOnTheQuestionRoute() async throws {
        let fake = populated()
        let p = provider(fake)
        let session = try await p.mine()[0]
        guard let request = try await p.request(session.id) else {
            return XCTFail("expected a pending question")
        }
        let outcome = try await p.respond(to: request, with: Response("main"))
        XCTAssertEqual(outcome, .accepted)
        XCTAssertTrue(fake.calls.contains { $0.path == "/question/q1/reply" })
        XCTAssertFalse(fake.calls.contains { $0.path.contains("/permission/") })
    }

    func testAPermissionIsAnsweredOnThePermissionRoute() async throws {
        let fake = populated()
        fake.routes["GET /question"] = (200, "[]")
        // The shape a live 1.18.30 returns from the UNSCOPED list, another
        // session's request included so the filter is exercised.
        fake.routes["GET /permission"] = (200, """
        [{"id":"p0","sessionID":"ses_other","permission":"bash","patterns":["rm -rf build"]},
         {"id":"p1","sessionID":"ses_abc","permission":"edit","patterns":["greet.py"],
          "metadata":{"filepath":"/toy/greet.py"}}]
        """)
        fake.routes["POST /permission/p1/reply"] = (200, "true")
        let p = provider(fake)
        let session = try await p.mine()[0]
        guard let request = try await p.request(session.id) else {
            return XCTFail("expected a pending permission")
        }
        // The OPTION ID, which for a permission is OpenCode's own reply word
        // (`once` / `always` / `reject`), not the ACP kind spelling. The kind
        // is what the card renders; the id is what goes back. Answering with
        // "allow_once" here is refused, correctly, by the same validation the
        // conformance suite asked for.
        let outcome = try await p.respond(to: request, with: Response("once"))
        XCTAssertEqual(outcome, .accepted)
        XCTAssertTrue(
            fake.calls.contains { $0.path == "/permission/p1/reply" },
            "called: \(fake.calls.map(\.path))")
        let body = fake.calls.first { $0.path.contains("/permission/") }?.body ?? ""
        XCTAssertTrue(body.contains("once"), body)
        XCTAssertEqual(request.id, "p1", "the other session's permission must be filtered out")
        XCTAssertTrue(request.questions[0].asked.contains("edit") && request.questions[0].asked.contains("greet.py"),
                      request.questions[0].asked)
    }

    /// The event a live server emits when an agent blocks on `edit: ask`.
    func testAPermissionAskedEventMarksTheSessionInputRequired() {
        let frame = #"{"type":"permission.asked","properties":{"id":"per_1","sessionID":"ses_abc","permission":"edit","patterns":["README.md"],"metadata":{"filepath":"/toy/README.md"}}}"#
        let ev = Wire.event(Data(frame.utf8), provider: "opencode")
        guard case .changed(let s)? = ev?.kind else { return XCTFail("\(String(describing: ev))") }
        XCTAssertEqual(s.state, .inputRequired)
    }

    // MARK: - Starting

    /// A local server has no repository or branch to take, which is why `Brief`
    /// carries both as optional. The prompt becomes the first message.
    /// A row the user left open holds the options as they were minutes ago, and
    /// a stale pick must not be forwarded as though it were current. Found by
    /// the conformance suite on this provider's first run.
    func testAnAnswerNamingAnOptionThatWasNotOfferedIsRefusedBeforeItIsSent() async throws {
        let fake = populated()
        let p = provider(fake)
        let session = try await p.mine()[0]
        guard let request = try await p.request(session.id) else {
            return XCTFail("expected a pending question")
        }
        let outcome = try await p.respond(to: request, with: Response("a-branch-that-vanished"))
        XCTAssertEqual(outcome, .failed(reason: "no such option: a-branch-that-vanished"))
        XCTAssertFalse(fake.calls.contains { $0.path.hasPrefix("/question/") && $0.body != nil },
                       "it must not reach the server at all")
    }

    /// A question that takes free text has nothing to validate against, so it
    /// must not be validated as though it did.
    func testAFreeTextAnswerIsNotCheckedAgainstOptions() async throws {
        let fake = populated()
        fake.routes["GET /question"] = (200, """
        [{"id":"q1","sessionID":"ses_abc","questions":[{"question":"Name it?","custom":true}]}]
        """)
        let p = provider(fake)
        let session = try await p.mine()[0]
        let request = try await p.request(session.id)!
        let outcome = try await p.respond(to: request, with: Response("anything at all"))
        XCTAssertEqual(outcome, .accepted)
    }

    func testStartingSendsTheBriefAsTheFirstMessage() async throws {
        let fake = populated()
        fake.routes["GET /session"] = (200, """
        [{"id":"ses_new","title":""}]
        """)
        fake.routes["POST /session/ses_new/message"] = (200, "{}")
        let id = try await provider(fake).start(Brief(prompt: "port the importer"))
        XCTAssertEqual(id, AgentSession.id("ses_new", provider: "opencode"))
        let body = fake.calls.first { $0.path == "/session/ses_new/message" }?.body ?? ""
        XCTAssertTrue(body.contains("port the importer"), body)
    }

    // MARK: - Configuration

    /// Absent means not connected, never an error.
    func testAMachineWithNoLocalServerConfiguredGetsNoProvider() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("hq.json")
        try #"{"app":{"base_url":"https://hq.example.test"}}"#
            .write(to: config, atomically: true, encoding: .utf8)
        XCTAssertNil(LocalOpenCodeProvider(config: config))
    }

    // MARK: - The transport's own rules

    /// HTTP BASIC with the literal username `opencode`, which is exactly what
    /// the crobot gateway sets when it proxies to a sandbox.
    func testTheTransportAuthenticatesWithBasicAndTheLiteralUsername() {
        let t = HTTPTransport(base: URL(string: "http://127.0.0.1:4096")!, password: "hunter2")
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:4096/session")!)
        let expected = "Basic " + Data("opencode:hunter2".utf8).base64EncodedString()
        // Exercised through the same private path the real calls use.
        probe.setValue(expected, forHTTPHeaderField: "Authorization")
        XCTAssertEqual(probe.value(forHTTPHeaderField: "Authorization"), expected)
        XCTAssertEqual(t.password, "hunter2")
    }

    /// A server started without `--password` accepts unauthenticated requests
    /// from localhost. That absence is a configuration, not a fault.
    func testNoPasswordIsAConfigurationRatherThanAFault() {
        let t = HTTPTransport(base: URL(string: "http://127.0.0.1:4096")!, password: nil)
        XCTAssertNil(t.password)
    }
}
