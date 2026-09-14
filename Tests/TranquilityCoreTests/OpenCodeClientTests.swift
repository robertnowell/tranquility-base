import XCTest
@testable import TranquilityCore

/// Every payload below is the real shape, copied from crobot's own
/// `ui/src/types.ts` against OpenCode SDK 1.18.29, which is the client
/// OpenCode publishes and crobot drives in production. Inventing fixtures is
/// how #367's two stubs agreed with each other and with nothing else.
final class OpenCodeClientTests: XCTestCase {

    // MARK: - A transport that opens no socket

    final class Fake: OpenCodeClient.Transport, @unchecked Sendable {
        var routes: [String: (Int, String)] = [:]
        private(set) var calls: [(method: String, path: String, body: String?)] = []
        var stream: [String] = []

        func send(method: String, path: String, body: Data?) async throws
            -> (status: Int, body: Data) {
            calls.append((method, path, body.flatMap { String(data: $0, encoding: .utf8) }))
            let (status, text) = routes["\(method) \(path)"] ?? routes[path] ?? (404, "")
            return (status, Data(text.utf8))
        }

        func events() -> AsyncStream<Data>? {
            guard !stream.isEmpty else { return nil }
            let frames = stream
            return AsyncStream { c in
                for f in frames { c.yield(Data(f.utf8)) }
                c.finish()
            }
        }
    }

    private func client(_ fake: Fake) -> OpenCodeClient {
        OpenCodeClient(transport: fake, provider: "opencode")
    }

    // MARK: - Sessions

    func testASessionDecodesWithItsTimestampInSeconds() async throws {
        let fake = Fake()
        fake.routes["GET /session"] = (200, """
        [{"id":"ses_abc","title":"tidy the fixtures","time":{"created":1757000000000,"updated":1757000600000}}]
        """)
        let sessions = try await client(fake).sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].title, "tidy the fixtures")
        XCTAssertEqual(sessions[0].provider, "opencode")
        // Milliseconds. Read as seconds this lands in the year 57000, sorts
        // every row to the top, and reads as a clock bug rather than a units
        // bug.
        XCTAssertEqual(sessions[0].updatedAt.timeIntervalSince1970, 1_757_000_600, accuracy: 1)
    }

    /// `/session` says a session EXISTS, never what it is doing. Inventing
    /// `.idle` from that is the failed-poll bug in another costume.
    /// A listed session takes its state from `/session/status`, which is the
    /// server's own first-hand answer, not from a guess and not from
    /// `.unknown`. Absent from the busy set means the turn is over.
    func testAListedSessionTakesItsStateFromTheStatusFeed() async throws {
        let fake = Fake()
        fake.routes["GET /session"] = (200, #"[{"id":"ses_abc"},{"id":"ses_busy"}]"#)
        fake.routes["GET /session/status"] =
            (200, #"[{"sessionID":"ses_busy","type":"running"}]"#)
        let sessions = try await client(fake).sessions()
        XCTAssertEqual(sessions.first(where: { $0.providerID == "ses_abc" })?.state, .completed)
        XCTAssertEqual(sessions.first(where: { $0.providerID == "ses_busy" })?.state, .working)
    }

    /// The object-keyed shape of the same route, which other builds return.
    func testTheStatusFeedIsReadInBothOfItsShapes() async throws {
        let fake = Fake()
        fake.routes["GET /session"] = (200, #"[{"id":"ses_abc"},{"id":"ses_busy"}]"#)
        fake.routes["GET /session/status"] =
            (200, #"{"ses_busy":{"type":"running"},"ses_abc":{"type":"idle"}}"#)
        let sessions = try await client(fake).sessions()
        XCTAssertEqual(sessions.first(where: { $0.providerID == "ses_busy" })?.state, .working)
        XCTAssertEqual(sessions.first(where: { $0.providerID == "ses_abc" })?.state, .completed)
    }

    /// Losing the enrichment costs blue, never the row, and must never report
    /// everything busy.
    func testAFailedStatusFeedStillYieldsRows() async throws {
        let fake = Fake()
        fake.routes["GET /session"] = (200, #"[{"id":"ses_abc"}]"#)
        fake.routes["GET /session/status"] = (500, "nope")
        let sessions = try await client(fake).sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .completed)
    }

    func testEveryIdIsAddressableWhateverOpenCodeCallsIt() async throws {
        let fake = Fake()
        fake.routes["GET /session"] = (200, #"[{"id":"ses/with spaces and !"}]"#)
        let session = try await client(fake).sessions().first
        XCTAssertTrue(ArtifactStore.isPlausibleSession(session!.id),
                      "an unaddressable id gets no hub page")
    }

    // MARK: - Transcript

    func testOnlyTextPartsBecomeTurns() async throws {
        let fake = Fake()
        fake.routes["GET /session/ses_abc/message"] = (200, """
        [{"info":{"id":"msg_1","role":"assistant","time":{"created":1757000000000}},
          "parts":[{"type":"text","text":"Reading the schema."},
                   {"type":"tool","tool":"bash","state":{"status":"completed"}}]},
         {"info":{"id":"msg_2","role":"assistant","time":{"created":1757000001000}},
          "parts":[{"type":"tool","tool":"bash"}]}]
        """)
        let turns = try await client(fake).transcript("ses_abc")
        XCTAssertEqual(turns.count, 1, "a tool-only message is not something the agent said")
        XCTAssertEqual(turns[0].text, "Reading the schema.")
        XCTAssertEqual(turns[0].role, .agent)
    }

    /// Attributing the agent's words to the user puts them in the wrong half of
    /// a transcript. An unknown role is far likelier to be a flavour of agent
    /// than a person.
    func testAnUnknownRoleReadsAsTheAgentAndNeverAsTheUser() async throws {
        let fake = Fake()
        fake.routes["GET /session/s/message"] = (200, """
        [{"info":{"id":"m","role":"orchestrator","time":{"created":1}},
          "parts":[{"type":"text","text":"hello"}]}]
        """)
        let role = try await client(fake).transcript("s").first?.role
        XCTAssertEqual(role, .agent)
    }

    // MARK: - Questions

    /// The shape that forced `PendingRequest` to carry an array. A request
    /// holds many questions, each with its own options and flags, answered
    /// together.
    func testAMultiQuestionRequestSurvivesIntact() async throws {
        let fake = Fake()
        fake.routes["GET /question"] = (200, """
        [{"id":"q1","sessionID":"ses_abc","questions":[
           {"question":"Which branch?","options":[{"label":"main"},{"label":"dev"}]},
           {"text":"Anything else?","custom":true,"multiple":true,"options":[]}]}]
        """)
        let request = try await client(fake).pendingRequest("ses_abc")
        XCTAssertEqual(request?.questions.count, 2)
        XCTAssertEqual(request?.questions[0].asked, "Which branch?")
        XCTAssertEqual(request?.questions[0].options.map(\.label), ["main", "dev"])
        XCTAssertEqual(request?.questions[1].asked, "Anything else?")
        XCTAssertTrue(request?.questions[1].allowsCustom == true)
        XCTAssertTrue(request?.questions[1].allowsMultiple == true)
    }

    /// Questions come from the UNSCOPED route and are filtered here. The
    /// session-scoped v1 route answers with QuestionNotFoundError, which is how
    /// a typed answer went nowhere in crobot (ui-owxd968g5sbf, 11 Sep 2026).
    func testQuestionsAreFetchedUnscopedAndFilteredBySession() async throws {
        let fake = Fake()
        fake.routes["GET /question"] = (200, """
        [{"id":"q1","sessionID":"other","questions":[{"question":"not yours"}]},
         {"id":"q2","sessionID":"ses_abc","questions":[{"question":"yours"}]}]
        """)
        let request = try await client(fake).pendingRequest("ses_abc")
        XCTAssertEqual(request?.id, "q2")
        XCTAssertTrue(fake.calls.contains { $0.path == "/question" },
                      "the unscoped route is the one that works")
        XCTAssertFalse(fake.calls.contains { $0.path.hasPrefix("/session/ses_abc/question") },
                       "the session-scoped route answers QuestionNotFoundError")
    }

    /// An amber row with nothing to say is worse than no row.
    func testARequestCarryingNoQuestionsIsNotARequest() async throws {
        let fake = Fake()
        fake.routes["GET /question"] = (200, #"[{"id":"q1","sessionID":"s","questions":[]}]"#)
        fake.routes["GET /api/session/s/permission"] = (200, "[]")
        let request = try await client(fake).pendingRequest("s")
        XCTAssertNil(request)
    }

    func testTheDataEnvelopeIsAcceptedAsWellAsABareArray() async throws {
        let fake = Fake()
        fake.routes["GET /question"] = (200, """
        {"data":[{"id":"q1","sessionID":"s","questions":[{"question":"wrapped?"}]}]}
        """)
        let asked = try await client(fake).pendingRequest("s")?.asked
        XCTAssertEqual(asked, "wrapped?")
    }

    // MARK: - Permissions

    /// A permission is the degenerate case: one question, three options, no
    /// free text. It needs no second type.
    func testAPermissionBecomesAOneQuestionRequestInACPsVocabulary() async throws {
        let fake = Fake()
        fake.routes["GET /question"] = (200, "[]")
        fake.routes["GET /api/session/s/permission"] = (200, """
        [{"id":"p1","sessionID":"s","action":"run rm -rf","resources":["build/"]}]
        """)
        let request = try await client(fake).pendingRequest("s")
        XCTAssertEqual(request?.id, "p1")
        XCTAssertEqual(request?.questions.count, 1)
        XCTAssertTrue(request!.asked.contains("build/"))
        XCTAssertEqual(request?.questions[0].options.map(\.kind),
                       [.allowOnce, .allowAlways, .rejectOnce])
    }

    /// The prefix is OpenCode's own inconsistency: questions live at
    /// `/question`, permissions at `/api/session/.../permission`.
    func testThePermissionRouteKeepsItsApiPrefix() async throws {
        let fake = Fake()
        fake.routes["GET /question"] = (200, "[]")
        fake.routes["GET /api/session/s/permission"] = (200, "[]")
        _ = try await client(fake).pendingRequest("s")
        XCTAssertTrue(fake.calls.contains { $0.path == "/api/session/s/permission" })
    }

    // MARK: - Answering

    func testAnsweringAQuestionPostsEveryAnswerInOrder() async throws {
        let fake = Fake()
        fake.routes["POST /question/q1/reply"] = (200, "{}")
        let request = PendingRequest(id: "q1", session: "s", questions: [
            .init(asked: "a"), .init(asked: "b"),
        ])
        let outcome = try await client(fake).respond(
            to: request, kind: .question, session: "s",
            with: Response(answers: [["main"], ["and this"]]))
        XCTAssertEqual(outcome, .accepted)
        let body = fake.calls.first { $0.path == "/question/q1/reply" }?.body ?? ""
        XCTAssertTrue(body.contains("main") && body.contains("and this"), body)
    }

    func testRejectingAQuestionUsesTheRejectRouteRatherThanAnEmptyAnswer() async throws {
        let fake = Fake()
        fake.routes["POST /question/q1/reject"] = (200, "{}")
        let request = PendingRequest(id: "q1", session: "s", asked: "?")
        let outcome = try await client(fake).respond(
            to: request, kind: .question, session: "s", with: .rejected)
        XCTAssertEqual(outcome, .accepted)
        XCTAssertTrue(fake.calls.contains { $0.path == "/question/q1/reject" })
    }

    /// A misread answer must never GRANT. Rejecting on anything unrecognised is
    /// the only safe direction.
    func testAnUnrecognisedPermissionAnswerRejectsRatherThanAllows() {
        let c = client(Fake())
        XCTAssertEqual(c.permissionReply(Response(answers: [["allow_once"]])), "once")
        XCTAssertEqual(c.permissionReply(Response(answers: [["always"]])), "always")
        XCTAssertEqual(c.permissionReply(Response(answers: [["yes please"]])), "reject")
        XCTAssertEqual(c.permissionReply(.rejected), "reject")
    }

    // MARK: - Asleep

    /// The gateway answers reads with 409 rather than waking a task, so an idle
    /// crobot task returns this on every poll. Normal, and not an error to log
    /// as one.
    func testAnAsleepSandboxIsItsOwnErrorAndNotAFailure() async {
        let fake = Fake()
        fake.routes["GET /session"] = (409, #"{"error":"the sandbox for this task is asleep"}"#)
        do {
            _ = try await client(fake).sessions()
            XCTFail("expected asleep")
        } catch let error as OpenCodeClient.ClientError {
            XCTAssertEqual(error, .asleep)
        } catch { XCTFail("wrong error: \(error)") }
    }

    /// A write wakes a sandbox, so a 409 there means it could not be woken,
    /// which is retryable rather than fatal.
    func testASendToAnAsleepSandboxIsBusyRatherThanFailed() async throws {
        let fake = Fake()
        fake.routes["POST /session/s/message"] = (409, "")
        let outcome = try await client(fake).send("hi", to: "s")
        XCTAssertEqual(outcome, .busy)
    }

    // MARK: - The stream

    /// Returning nil IS the poll-or-push declaration handed upward.
    func testNoStreamMeansPollMeInstead() {
        XCTAssertNil(client(Fake()).events())
    }

    /// Every frame below is VERBATIM from a live `opencode serve` 1.18.30
    /// driven through a real turn, not invented. The first draft's fixtures
    /// were guesses and two of the four event names were wrong, which is why
    /// the stream yielded nothing at all against a real server.
    func testTheStreamYieldsSpeechAndABlockingRequest() async {
        let fake = Fake()
        fake.stream = [
            #"{"type":"server.connected","properties":{}}"#,
            #"{"type":"message.part.updated","properties":{"sessionID":"s","part":{"type":"text","text":"Cleaning up.","messageID":"msg_1","sessionID":"s","id":"prt_1"},"time":1789356676239}}"#,
            #"{"type":"question.updated","properties":{"sessionID":"s"}}"#,
            #"{"type":"session.status","properties":{"sessionID":"s","status":{"type":"idle"}}}"#,
        ]
        guard let stream = client(fake).events() else { return XCTFail("expected a stream") }
        var kinds: [String] = []
        for await event in stream {
            switch event.kind {
            case .said: kinds.append("said")
            case .changed(let s): kinds.append("changed:\(s.state.rawValue)")
            default: kinds.append("other")
            }
        }
        XCTAssertEqual(kinds, ["said", "changed:input-required", "changed:completed"],
                       "server.connected carries no session and is correctly dropped")
    }

    /// A text part carries its OWN id. The first draft fell back to
    /// `part.type`, so every text part in a session shared the id "text".
    func testATextPartKeepsItsOwnIdRatherThanItsType() async {
        let fake = Fake()
        fake.stream = [
            #"{"type":"message.part.updated","properties":{"sessionID":"s","part":{"type":"text","text":"one","messageID":"msg_1","id":"prt_1"}}}"#,
            #"{"type":"message.part.updated","properties":{"sessionID":"s","part":{"type":"text","text":"two","messageID":"msg_1","id":"prt_2"}}}"#,
        ]
        var ids: [String] = []
        for await event in client(fake).events()! {
            if case .said(let turn) = event.kind { ids.append(turn.id) }
        }
        XCTAssertEqual(ids, ["prt_1", "prt_2"], "two parts must not share one id")
    }

    /// `session.status` is the first-hand working signal, rather than inferring
    /// it from whether a message arrived recently.
    func testSessionStatusCarriesTheWorkingSignalFirstHand() async {
        let fake = Fake()
        fake.stream = [
            #"{"type":"session.status","properties":{"sessionID":"s","status":{"type":"busy"}}}"#,
        ]
        var states: [AgentSessionState] = []
        for await event in client(fake).events()! {
            if case .changed(let s) = event.kind { states.append(s.state) }
        }
        XCTAssertEqual(states, [.working])
    }

    /// A delta is a fragment that `message.part.updated` then delivers whole.
    /// Emitting both reads the same sentence out twice.
    func testAPartialDeltaIsNotSpokenTwice() async {
        let fake = Fake()
        fake.stream = [
            #"{"type":"message.part.delta","properties":{"sessionID":"s","part":{"type":"text","text":"Clean","id":"prt_1"}}}"#,
            #"{"type":"message.part.updated","properties":{"sessionID":"s","part":{"type":"text","text":"Cleaning up.","id":"prt_1"}}}"#,
        ]
        var said: [String] = []
        for await event in client(fake).events()! {
            if case .said(let turn) = event.kind { said.append(turn.text) }
        }
        XCTAssertEqual(said, ["Cleaning up."])
    }

    /// A session appearing is news; claiming it is idle is not. Inventing a
    /// state here would overwrite a `busy` that session.status just reported.
    func testASessionCreatedEventDoesNotInventAState() async {
        let fake = Fake()
        fake.stream = [
            #"{"type":"session.created","properties":{"sessionID":"s","info":{"id":"s","title":"New session"}}}"#,
        ]
        var states: [AgentSessionState] = []
        for await event in client(fake).events()! {
            if case .changed(let s) = event.kind { states.append(s.state) }
        }
        XCTAssertEqual(states, [.unknown])
    }

    /// OpenCode emits many event types and adds more. Falling over on an
    /// unfamiliar one would break this on a release nobody here controls.
    func testAnUnknownEventIsIgnoredRatherThanFatal() async {
        let fake = Fake()
        fake.stream = [
            #"{"type":"something.invented.later","properties":{"sessionID":"s"}}"#,
            "not json at all",
            #"{"type":"session.idle","properties":{"sessionID":"s"}}"#,
        ]
        var count = 0
        for await _ in client(fake).events()! { count += 1 }
        XCTAssertEqual(count, 1, "the good event still arrived")
    }
}
