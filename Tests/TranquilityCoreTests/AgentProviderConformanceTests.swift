import XCTest
@testable import TranquilityCore

/// The third conformance, and the one the suite runs against by default.
///
/// Deliberately the most CAPABLE provider: everything true, a stream, and a
/// structural answer. The other two stubs each refuse something, so between
/// the three of them every branch of the suite is taken in both directions.
///
/// This is also the template. Adding a real provider should look like this file
/// with a transport behind it, and the conformance suite should pass unchanged.
struct ConformanceStub: AgentProvider, Sendable {
    let id = "conformance-stub"
    var can = Capabilities(canStart: true, canSend: true, canAnswer: true, canCancel: true,
                           sendWhileWorking: true, listIsCallerScoped: true,
                           carriesPullRequest: true)

    static let blocked = AgentSession(
        id: "d3d94468-02a4-4f9f-8a9b-bd0b3e2e8e21", provider: "conformance-stub",
        title: "the one that is asking", state: .inputRequired,
        updatedAt: Date(timeIntervalSince1970: 1_757_000_300),
        repository: "acme/thing",
        pullRequest: URL(string: "https://github.com/acme/thing/pull/9"))

    static let question = PendingRequest(
        id: "q-1", session: blocked.id, asked: "Which branch should it target?",
        options: [.init(id: "main", label: "main"), .init(id: "dev", label: "dev")])

    func changes() -> AsyncStream<AgentEvent>? {
        AsyncStream { c in
            c.yield(AgentEvent(provider: id, session: Self.blocked.id,
                               at: Self.blocked.updatedAt, kind: .appeared(Self.blocked)))
            c.yield(AgentEvent(provider: id, session: Self.blocked.id,
                               at: Self.blocked.updatedAt, kind: .asks(Self.question)))
            c.finish()
        }
    }

    func mine() async throws -> [AgentSession] { [Self.blocked] }
    func refine(_ id: AgentSession.ID) async throws -> AgentSession { Self.blocked }
    func request(_ id: AgentSession.ID) async throws -> PendingRequest? {
        id == Self.blocked.id ? Self.question : nil
    }
    func transcript(_ id: AgentSession.ID) async throws -> [Turn] { [] }
    func send(_ text: String, to id: AgentSession.ID) async throws -> SendOutcome { .accepted }
    func respond(to request: PendingRequest, with response: Response) async throws -> SendOutcome {
        if case .option(let chosen) = response,
           !request.options.contains(where: { $0.id == chosen }) {
            return .failed(reason: "no such option: \(chosen)")
        }
        return .accepted
    }
    func start(_ brief: Brief) async throws -> AgentSession.ID {
        AgentSession.id("conf-\(brief.prompt.count)", provider: id)
    }
    func cancel(_ id: AgentSession.ID) async throws -> SendOutcome { .accepted }
    func url(for id: AgentSession.ID) -> URL? {
        URL(string: "https://conformance.example.test/\(id)")
    }
}

/// One suite, every provider. When crobot and local OpenCode land (#368), they
/// are added to `all` below and nothing else changes.
final class AgentProviderConformanceTests: XCTestCase {

    private var all: [any AgentProvider] {
        [ConformanceStub(), PolledStub(), StreamingStub(), MinimalStub()]
    }

    /// `egress: true` because these are fixtures, which is exactly the case
    /// the default is written to distinguish from. Against a live provider the
    /// mutating half stays off unless somebody says otherwise in writing.
    func testEveryProviderConforms() async throws {
        for provider in all {
            try await AgentProviderConformance.run(provider, egress: true)
        }
    }

    /// Between the three of them, every branch of the suite is taken in both
    /// directions. A suite where no provider ever refuses anything proves
    /// nothing about refusal, which is most of what this seam does.
    func testTheStubsBetweenThemExerciseBothSidesOfEveryCapability() {
        let caps = all.map(\.can)
        for path in [\Capabilities.canSend, \Capabilities.canAnswer,
                     \Capabilities.canCancel, \Capabilities.sendWhileWorking,
                     \Capabilities.listIsCallerScoped, \Capabilities.carriesPullRequest] {
            XCTAssertTrue(caps.contains { $0[keyPath: path] },
                          "no stub declares this capability true")
            XCTAssertTrue(caps.contains { !$0[keyPath: path] },
                          "no stub declares this capability false, so its refusal is untested")
        }
    }

    /// One polled, one pushing, at minimum. Two request-response providers
    /// would not have exercised the half that matters.
    func testTheStubsCoverBothIngressShapes() {
        // `changes()` called once each, and the result kept. It is not a
        // predicate: for a real provider it opens a subscription.
        let streams = all.map { $0.changes() }
        XCTAssertTrue(streams.contains { $0 != nil }, "no stub streams")
        XCTAssertTrue(streams.contains { $0 == nil }, "no stub is polled")
    }

    /// A blocking inbound request must be expressible as an EVENT, not only as
    /// something a poller discovers by asking. If this cannot be written, the
    /// protocol is wrong, and finding that out in a fixture costs an hour
    /// rather than a rewrite after the first real provider is built on it.
    func testABlockingRequestCanArriveThroughTheStream() async {
        var asked: PendingRequest?
        guard let stream = StreamingStub().changes() else {
            return XCTFail("the streaming stub stopped streaming")
        }
        for await event in stream {
            if case .asks(let request) = event.kind { asked = request }
        }
        XCTAssertNotNil(asked, "a blocking request has nowhere to land in the event model")
        XCTAssertFalse(asked?.options.isEmpty ?? true,
                       "a permission request with no options cannot be answered structurally")
    }

    /// The acceptance test for #366, stated as a test rather than as a hope:
    /// a third provider is one file plus one registry entry.
    func testAThirdProviderIsOneFileAndOneRegistryEntry() {
        let registry = AgentProviderRegistry(all)
        XCTAssertEqual(registry.providers.count, 4)
        XCTAssertNotNil(registry.provider("conformance-stub"))
        XCTAssertNil(registry.provider("not-registered"))
    }

    // MARK: - The digest

    /// Excluded from the digest deliberately: several vendors move `updatedAt`
    /// on a poll that changed nothing observable, and including it would make
    /// the digest change every tick, which is the exact failure it exists to
    /// prevent.
    func testAMovingTimestampAloneIsNotAChange() {
        var a = ConformanceStub.blocked
        var b = a
        b.updatedAt = a.updatedAt.addingTimeInterval(600)
        XCTAssertEqual(AgentPoll.digest(a), AgentPoll.digest(b))
        a.state = .completed
        XCTAssertNotEqual(AgentPoll.digest(a), AgentPoll.digest(b))
    }

    /// Absence from one poll is not an ending. crobot's list has no creator
    /// filter and several vendors paginate, so a short list is not evidence
    /// that an agent finished. An ending is a state.
    func testAnAgentVanishingFromTheListIsNotAnEnding() {
        let opening = AgentPoll.events(from: [:], to: [ConformanceStub.blocked])
        let gone = AgentPoll.events(from: opening.digests, to: [])
        XCTAssertTrue(gone.events.isEmpty,
                      "a short poll invented an ending for an agent that is still running")
    }
}
