import XCTest
@testable import TranquilityCore

/// OpenCode 2.x, against payloads copied from a live `opencode serve` 2.0.23
/// on 6 Oct 2026: a turn, a shell permission, a question form, a cancelled
/// form and an interrupt. The 1.x tests stay as they are: crobot still runs
/// 1.x, and `.v1` is the default for exactly that reason.
final class OpenCodeV2Tests: XCTestCase {

    typealias Fake = OpenCodeClientTests.Fake

    private func client(_ fake: Fake, directory: String? = "/toy") -> OpenCodeClient {
        OpenCodeClient(transport: fake, provider: "opencode", api: .v2(directory: directory))
    }

    // MARK: - Routes

    func testTheSessionListIsScopedToTheWorkspaceAndReadsBusyFromActive() async throws {
        let fake = Fake()
        fake.routes["GET /api/session?order=desc&limit=200&directory=%2Ftoy"] = (200, """
        {"data":[{"id":"ses_a","title":"Pong response","time":{"created":1791325736439,"updated":1791325737713}},
                 {"id":"ses_b","title":"research","parentID":"ses_a","time":{"created":1791325736439}}],
         "cursor":{"next":null}}
        """)
        fake.routes["GET /api/session/active"] = (200, #"{"data":{"ses_a":{"type":"running"}}}"#)
        let c = client(fake)
        let sessions = try await c.sessions()
        XCTAssertEqual(sessions.map(\.providerID), ["ses_a", "ses_b"])
        XCTAssertEqual(sessions.first?.state, .working)
        XCTAssertEqual(sessions.last?.state, .completed)
        let children = try await c.childSessionIDs()
        XCTAssertEqual(children, ["ses_b"])
    }

    func testStartReadsTheIdOutOfTheDataEnvelope() async throws {
        let fake = Fake()
        fake.routes["POST /api/session"] = (200, #"{"data":{"id":"ses_new","projectID":"p","time":{"created":1}}}"#)
        let id = try await client(fake).start()
        XCTAssertEqual(id, AgentSession.id("ses_new", provider: "opencode"))
    }

    /// The one prompt route, with `text` rather than parts. The 405 that
    /// started this was the 1.x `POST /session` landing on the web app.
    func testAPromptGoesToThePromptRouteAsText() async throws {
        let fake = Fake()
        fake.routes["POST /api/session/ses_a/prompt"] = (200, #"{"data":{"id":"msg_1","type":"user"}}"#)
        let outcome = try await client(fake).sendAsync("hello", to: "ses_a")
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(fake.calls.last?.body, #"{"text":"hello"}"#)
    }

    func testAbortIsInterrupt() async throws {
        let fake = Fake()
        fake.routes["POST /api/session/ses_a/interrupt"] = (200, #"{"interrupted":true}"#)
        try await client(fake).abort("ses_a")
        XCTAssertEqual(fake.calls.last?.path, "/api/session/ses_a/interrupt")
    }

    /// Oldest first, user and agent told apart by `type`, the `idle` marker
    /// and a tool-only step not turns at all.
    func testTheTranscriptReadsTheTimelineOldestFirst() async throws {
        let fake = Fake()
        fake.routes["GET /api/session/ses_a/message?order=asc&limit=200"] = (200, """
        {"data":[
          {"id":"msg_u","time":{"created":1791325737031},"text":"Reply with exactly the word: pong","type":"user"},
          {"id":"msg_t","time":{"created":1791325737035},"type":"assistant","content":[{"type":"tool","id":"toolu_1","name":"shell"}]},
          {"id":"msg_a","time":{"created":1791325737041},"type":"assistant","content":[{"type":"text","text":"pong"}],"finish":"stop"},
          {"id":"msg_i","time":{"created":1791325738334},"type":"idle","outcome":"succeeded"}],
         "cursor":{"next":"abc"}}
        """)
        let turns = try await client(fake).transcript("ses_a")
        XCTAssertEqual(turns.map(\.id), ["msg_u", "msg_a"])
        XCTAssertEqual(turns.map(\.role), [.user, .agent])
        XCTAssertEqual(turns.last?.text, "pong")
    }

    // MARK: - Permissions

    func testAPermissionIsReadAndAnsweredUnderItsSession() async throws {
        let fake = Fake()
        fake.routes["GET /api/session/ses_a/permission"] = (200, """
        {"data":[{"id":"per_1","sessionID":"ses_a","action":"shell","resources":["echo hello-tb"],"save":["echo *"]}]}
        """)
        fake.routes["GET /api/session/ses_a/form"] = (200, #"{"data":[]}"#)
        fake.routes["POST /api/session/ses_a/permission/per_1/reply"] = (204, "")
        let c = client(fake)
        let pending = try await c.pendingRequest("ses_a")
        XCTAssertEqual(pending?.id, "per_1")
        XCTAssertEqual(pending?.questions.first?.asked, "Allow shell on echo hello-tb?")
        let outcome = try await c.respond(to: pending!, kind: .permission, session: "ses_a",
                                          with: Response("once"))
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(fake.calls.last?.body, #"{"decision":"once"}"#)
    }

    // MARK: - Questions, which are forms now

    private let form = """
    {"id":"frm_1","sessionID":"ses_a","title":"Questions","metadata":{"kind":"question"},
     "fields":[{"key":"q0","title":"Color preference","description":"Do you prefer red or blue?","type":"string",
                "options":[{"value":"Red","label":"Red","description":"I prefer red"},
                           {"value":"Blue","label":"Blue","description":"I prefer blue"}],"custom":true}]}
    """

    func testAQuestionFormIsReadAsAQuestionAndAnsweredByFieldKey() async throws {
        let fake = Fake()
        fake.routes["GET /api/session/ses_a/form"] = (200, #"{"data":[\#(form)]}"#)
        fake.routes["GET /api/session/ses_a/form/frm_1"] = (200, #"{"data":\#(form)}"#)
        fake.routes["POST /api/session/ses_a/form/frm_1/reply"] = (204, "")
        let c = client(fake)
        let pending = try await c.pendingRequest("ses_a")
        XCTAssertEqual(pending?.questions.first?.asked, "Do you prefer red or blue?")
        XCTAssertEqual(pending?.questions.first?.options.map(\.id), ["Red", "Blue"])
        XCTAssertEqual(pending?.questions.first?.allowsCustom, true)
        let outcome = try await c.respond(to: pending!, kind: .question, session: "ses_a",
                                          with: Response("Blue"))
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(fake.calls.last?.body, #"{"answer":{"q0":"Blue"}}"#)
    }

    func testARejectedQuestionDeletesTheForm() async throws {
        let fake = Fake()
        fake.routes["DELETE /api/session/ses_a/form/frm_1"] = (204, "")
        let request = PendingRequest(id: "frm_1", session: AgentSession.id("ses_a", provider: "opencode"),
                                     questions: [])
        let outcome = try await client(fake).respond(to: request, kind: .question, session: "ses_a",
                                                     with: .rejected)
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(fake.calls.last?.method, "DELETE")
    }

    func testAMultiselectAnswerIsAnArray() throws {
        let data = Data("""
        {"id":"frm_2","sessionID":"s","fields":[{"key":"q0","description":"Which?","type":"multiselect","options":[{"value":"a"},{"value":"b"}]}]}
        """.utf8)
        let form = try JSONDecoder().decode(Wire.V2.Form.self, from: data)
        XCTAssertEqual(form.answer([["a", "b"]])["q0"] as? [String], ["a", "b"])
        XCTAssertEqual(form.pending(session: "x")?.questions.first?.allowsMultiple, true)
    }

    // MARK: - The pieces around the client

    func testTheVersionIsReadFromEitherSpelling() {
        XCTAssertEqual(OpenCodeServer.majorVersion(of: "opencode v2.0.23\n"), 2)
        XCTAssertEqual(OpenCodeServer.majorVersion(of: "1.18.31\n"), 1)
        XCTAssertEqual(OpenCodeServer.majorVersion(of: "garbage"), 1)
    }

    func testEvery2xMomentMapsToThe1xWordTheProviderActsOn() {
        let map = ServedOpenCodeProvider.v1Equivalent
        XCTAssertEqual(map("session.execution.started"), "session.status.busy")
        XCTAssertEqual(map("session.execution.succeeded"), "session.idle")
        XCTAssertEqual(map("session.execution.interrupted"), "session.idle")
        XCTAssertEqual(map("session.execution.failed"), "session.error")
        XCTAssertEqual(map("form.created"), "permission.asked")
        XCTAssertEqual(map("form.cancelled"), "permission.replied")
        XCTAssertEqual(map("session.renamed"), "session.updated")
        XCTAssertNil(map("session.text.delta"))
    }

    func testAPathWithAQueryKeepsItsQuery() {
        let t = HTTPTransport(base: URL(string: "http://127.0.0.1:4096")!, password: nil)
        XCTAssertEqual(t.url("/api/session?order=desc&limit=200").absoluteString,
                       "http://127.0.0.1:4096/api/session?order=desc&limit=200")
        XCTAssertEqual(t.url("/session").absoluteString, "http://127.0.0.1:4096/session")
    }

    func testA1xServerKeepsItsAttachDoorAndSendsNoPassword() async throws {
        let server = OpenCodeServer(binary: "/bin/echo", directory: "/tmp", port: 4999)
        XCTAssertTrue(server.attachCommand(session: "ses_a").contains("'attach'"))
        XCTAssertNil(server.transportPassword)
    }
}
