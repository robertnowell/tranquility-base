import XCTest
@testable import TranquilityCore

/// Answering a remote agent uses the same verb as answering a local one, and
/// these mostly pin the places where it must NOT quietly behave differently.
final class RemoteDispatchTransportTests: XCTestCase {

    final class Provider: AgentProvider, @unchecked Sendable {
        let id = "crobot"
        var can = Capabilities(canStart: true, canSend: true, canAnswer: true,
                               sendWhileWorking: false, listIsCallerScoped: true)
        var sendResult: SendOutcome = .accepted
        var respondResult: SendOutcome = .accepted
        var throwOnSend = false
        private(set) var sent: [String] = []
        private(set) var answered: [Response] = []

        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

        func changes() -> AsyncStream<AgentEvent>? { nil }
        func mine() async throws -> [AgentSession] { [] }
        func refine(_ id: AgentSession.ID) async throws -> AgentSession { throw Boom() }
        func request(_ id: AgentSession.ID) async throws -> PendingRequest? { nil }
        func transcript(_ id: AgentSession.ID) async throws -> [Turn] { [] }
        func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome {
            if throwOnSend { throw Boom() }
            sent.append(text)
            return sendResult
        }
        func respond(to r: PendingRequest, with response: Response) async throws -> SendOutcome {
            answered.append(response)
            return respondResult
        }
        func start(_ brief: Brief) async throws -> AgentSession.ID { "x" }
        func cancel(_ id: AgentSession.ID) async throws -> SendOutcome { .unsupported }
        func url(for id: AgentSession.ID) -> URL? { nil }
    }

    private let id = AgentSession.id("s1", provider: "crobot")

    private func transport(_ p: Provider, state: AgentSessionState = .completed,
                           pending: PendingRequest? = nil) -> RemoteDispatchTransport {
        var session = AgentSession.of("s1", provider: "crobot", state: state)
        session.state = state
        let captured = session
        return RemoteDispatchTransport(
            registry: AgentProviderRegistry([p]),
            agent: { $0 == captured.id ? captured : nil },
            pending: { _ in pending })
    }

    private var target: DispatchTarget {
        DispatchTarget(kind: .remote, sessionId: id, readinessSource: .provider)
    }

    // MARK: - Readiness

    func testAWaitingAgentIsDispatchableAndCarriesItsQuestion() async {
        let request = PendingRequest(id: "q", session: id, asked: "Merge to main?")
        let r = await transport(Provider(), state: .inputRequired, pending: request)
            .readiness(for: target)
        XCTAssertEqual(r, .waiting("Merge to main?"))
    }

    /// The provider decides whether a mid-turn send lands. Deferring here is
    /// cheaper than a round trip that comes back busy.
    func testAWorkingAgentDefersWhenTheProviderRefusesMidTurnSends() async {
        let p = Provider()
        p.can.sendWhileWorking = false
        let refusing = await transport(p, state: .working).readiness(for: target)
        XCTAssertEqual(refusing, .busy)
        p.can.sendWhileWorking = true
        let accepting = await transport(p, state: .working).readiness(for: target)
        XCTAssertEqual(accepting, .ready)
    }

    /// **Never dispatch on silence.** The reply would go to an agent whose
    /// state we lost, and the poller has already recorded why it is quiet.
    func testAnUnknownAgentIsNotDispatchedTo() async {
        let r = await transport(Provider(), state: .unknown).readiness(for: target)
        XCTAssertEqual(r, .notRegistered)
    }

    /// A provider with no reply verb is alive and simply cannot take one.
    /// Calling that `targetGone` would be a lie the user acts on.
    func testAProviderThatCannotReplyIsNotReportedAsGone() async {
        let p = Provider()
        p.can.canSend = false
        p.can.canAnswer = false
        let r = await transport(p).readiness(for: target)
        XCTAssertEqual(r, .notRegistered)
        XCTAssertNotEqual(r, .targetGone)
    }

    /// Sending to a finished session is how a conversation continues.
    func testAFinishedAgentIsStillAnswerable() async {
        let r = await transport(Provider(), state: .completed).readiness(for: target)
        XCTAssertEqual(r, .ready)
    }

    // MARK: - A question gets an answer, not a message

    /// Prose sent at a pending permission is a typed answer that goes nowhere.
    func testAPendingQuestionIsAnsweredStructurallyRatherThanMessaged() async {
        let p = Provider()
        let request = PendingRequest(id: "q", session: id, asked: "Merge?")
        let outcome = await transport(p, state: .inputRequired, pending: request)
            .send(text: "yes", to: target)

        if case .confirmed = outcome {} else { XCTFail("expected confirmed, got \(outcome)") }
        XCTAssertEqual(p.answered.count, 1, "it should have answered the question")
        XCTAssertTrue(p.sent.isEmpty, "and not sent a loose message")
    }

    func testWithNoQuestionItSendsAMessage() async {
        let p = Provider()
        let outcome = await transport(p).send(text: "carry on", to: target)
        if case .confirmed = outcome {} else { XCTFail("expected confirmed, got \(outcome)") }
        XCTAssertEqual(p.sent, ["carry on"])
        XCTAssertTrue(p.answered.isEmpty)
    }

    // MARK: - busy is surfaced, never swallowed

    /// Cursor refuses a follow-up while an agent is working. A user who hears
    /// nothing assumes their words landed.
    func testBusyComesBackAsDeferredRatherThanSilence() async {
        let p = Provider()
        p.sendResult = .busy
        let outcome = await transport(p).send(text: "hi", to: target)
        guard case .deferred(let readiness) = outcome else {
            return XCTFail("expected deferred, got \(outcome)")
        }
        XCTAssertEqual(readiness, .busy)
    }

    /// A polite refusal in words, not an obscure failure.
    func testAnUnsupportedVerbRefusesInWordsNamingTheProvider() async {
        let p = Provider()
        p.sendResult = .unsupported
        let outcome = await transport(p).send(text: "hi", to: target)
        guard case .failed(.notEnrolled(let why)) = outcome else {
            return XCTFail("expected a named refusal, got \(outcome)")
        }
        XCTAssertTrue(why.contains("crobot"), why)
        XCTAssertTrue(why.contains("send"), why)
    }

    func testAFailureCarriesItsReason() async {
        let p = Provider()
        p.sendResult = .failed(reason: "502 from the gateway")
        guard case .failed(.injectionFailed(let why)) = await transport(p)
            .send(text: "hi", to: target) else {
            return XCTFail("expected a reasoned failure")
        }
        XCTAssertTrue(why.contains("502"), why)
    }

    func testAThrownErrorIsAReasonedFailureRatherThanACrash() async {
        let p = Provider()
        p.throwOnSend = true
        guard case .failed(.injectionFailed(let why)) = await transport(p)
            .send(text: "hi", to: target) else {
            return XCTFail("expected a reasoned failure")
        }
        XCTAssertTrue(why.contains("boom"), why)
    }

    // MARK: - Accepted is a receipt

    /// A local send watches the screen to learn whether it landed. This one
    /// was told, so `confirmed` is honest rather than optimistic.
    func testAnAcceptedSendIsConfirmedWithALatency() async {
        let outcome = await transport(Provider()).send(text: "hi", to: target)
        guard case .confirmed(let ms) = outcome else {
            return XCTFail("expected confirmed, got \(outcome)")
        }
        XCTAssertGreaterThanOrEqual(ms, 0)
    }

    func testAnAgentThePollerHasNeverSeenIsGone() async {
        let t = RemoteDispatchTransport(registry: AgentProviderRegistry([Provider()]),
                                        agent: { _ in nil }, pending: { _ in nil })
        let r = await t.readiness(for: target)
        XCTAssertEqual(r, .targetGone)
        guard case .failed(.targetGone) = await t.send(text: "hi", to: target) else {
            return XCTFail("expected targetGone")
        }
    }

    /// A remote target never reaches the tmux transport, and if it somehow did
    /// it must refuse rather than type into somebody else's pane.
    func testTheTmuxTransportRefusesARemoteTarget() async {
        let r = await TmuxTransport().readiness(for: target)
        XCTAssertEqual(r, .targetGone)
    }
}
