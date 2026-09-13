import XCTest
@testable import TranquilityCore

/// The model's own rules, as opposed to what a provider must do with it (that
/// is `AgentProviderConformanceTests`). Every one of these is a decision that
/// gets expensive later.
final class AgentSessionTests: XCTestCase {

    // MARK: - Rule 1: unknown means ignore, missing means absent

    /// A vendor adding a state must not be able to empty the grid.
    func testAnUnrecognisedStateDecodesToUnknownRatherThanThrowing() throws {
        struct Wire: Decodable { var state: AgentSessionState }
        let json = Data(#"{"state": "hibernating-in-a-cave"}"#.utf8)
        let decoded = try JSONDecoder().decode(Wire.self, from: json)
        XCTAssertEqual(decoded.state, .unknown)
    }

    func testEveryA2AStateSurvivesTheRoundTrip() throws {
        for state in AgentSessionState.allCases {
            struct Wire: Codable { var state: AgentSessionState }
            let data = try JSONEncoder().encode(Wire(state: state))
            XCTAssertEqual(try JSONDecoder().decode(Wire.self, from: data).state, state)
        }
    }

    /// The hyphenated spellings are A2A's, borrowed verbatim rather than
    /// re-invented. A camelCased wire value would be a different protocol.
    func testTheBlockedStatesKeepA2ASpelling() {
        XCTAssertEqual(AgentSessionState.inputRequired.rawValue, "input-required")
        XCTAssertEqual(AgentSessionState.authRequired.rawValue, "auth-required")
    }

    func testOnlyTheTwoPausedStatesCountAsBlocked() {
        let blocked = AgentSessionState.allCases.filter(\.isBlocked)
        XCTAssertEqual(Set(blocked), [.inputRequired, .authRequired])
    }

    func testTheFinishedStatesAreA2AsFinishedGroup() {
        let finished = AgentSessionState.allCases.filter(\.isFinished)
        XCTAssertEqual(Set(finished), [.failed, .completed, .canceled, .rejected])
    }

    /// A failed poll yields unknown, and unknown is neither finished nor
    /// blocked: not hearing from a provider is not evidence that its agents
    /// finished, and it is not evidence that they need you either.
    func testUnknownIsNeitherFinishedNorBlocked() {
        XCTAssertFalse(AgentSessionState.unknown.isFinished)
        XCTAssertFalse(AgentSessionState.unknown.isBlocked)
    }

    // MARK: - Ids

    /// `ArtifactStore.isPlausibleSession` refuses anything else, and a refused
    /// id gets no hub page at all.
    func testEveryIdIsAddressableWhateverTheProviderCallsIt() {
        let raws = ["8f14e45f-ceea-467a-9eef-2b9c1b2dc9f0",
                    "task_9931/with slashes and spaces",
                    "",
                    String(repeating: "z", count: 300),
                    "ünïcödé"]
        for raw in raws {
            let id = AgentSession.id(raw, provider: "p")
            XCTAssertTrue(ArtifactStore.isPlausibleSession(id),
                          "\(raw.prefix(20)) produced an unaddressable id: \(id)")
        }
    }

    /// A recognisable id is worth a great deal when somebody is reading a log,
    /// so an id that is already addressable is kept rather than hashed.
    func testAnAlreadyPlausibleIdIsKeptVerbatim() {
        let uuid = "8f14e45f-ceea-467a-9eef-2b9c1b2dc9f0"
        XCTAssertEqual(AgentSession.id(uuid, provider: "crobot"), uuid)
    }

    /// Hashed rather than stripped, because two names differing only in a
    /// character the filter would remove must not become one row.
    func testNamesThatDifferOnlyInFilteredCharactersDoNotCollide() {
        let a = AgentSession.id("fix the bug", provider: "p")
        let b = AgentSession.id("fix_the_bug", provider: "p")
        XCTAssertNotEqual(a, b)
    }

    func testTwoProvidersCannotMintTheSameIdFromTheSameRawString() {
        XCTAssertNotEqual(AgentSession.id("session one", provider: "crobot"),
                          AgentSession.id("session one", provider: "opencode"))
    }

    // MARK: - The buckets are computed, and their precedence is the rule

    /// A blocking request outranks everything, which is the same precedence the
    /// local grid holds: a process saying it cannot go on alone is the one
    /// thing whose tap actually helps.
    func testABlockingRequestOutranksUnreadAndWorking() {
        XCTAssertEqual(
            AgentPresentation.bucket(state: .working, hasPendingRequest: true, hasUnread: true),
            .needsYou)
        XCTAssertEqual(
            AgentPresentation.bucket(state: .inputRequired, hasPendingRequest: false,
                                     hasUnread: false),
            .needsYou)
    }

    /// Green and amber are the two channels that mean *you*. Advisory blue must
    /// not mask either.
    func testUnreadOutranksWorking() {
        XCTAssertEqual(
            AgentPresentation.bucket(state: .working, hasPendingRequest: false, hasUnread: true),
            .unread)
        XCTAssertEqual(
            AgentPresentation.bucket(state: .working, hasPendingRequest: false, hasUnread: false),
            .working)
    }

    /// A finished agent with something you have not read is still asking for
    /// you. Filing it as done is how a result goes unheard.
    func testAFinishedAgentWithSomethingUnreadIsStillUnread() {
        XCTAssertEqual(
            AgentPresentation.bucket(state: .completed, hasPendingRequest: false, hasUnread: true),
            .unread)
        XCTAssertEqual(
            AgentPresentation.bucket(state: .completed, hasPendingRequest: false, hasUnread: false),
            .done)
    }

    /// An unreachable provider's agents are UNREACHABLE, not quiet. Folding
    /// the two together made a captive portal render as a grid of calm agents,
    /// with every lamp lying by omission.
    func testUnknownIsItsOwnBucketAndNotIdle() {
        XCTAssertEqual(
            AgentPresentation.bucket(state: .unknown, hasPendingRequest: false, hasUnread: false),
            .unreachable)
        XCTAssertNotEqual(
            AgentPresentation.bucket(state: .unknown, hasPendingRequest: false, hasUnread: false),
            AgentPresentation.bucket(state: .completed, hasPendingRequest: false,
                                     hasUnread: false),
            "silence must not read as finished")
    }

    /// Something it said before we lost contact is still something you have
    /// not read, and silence since does not retract it.
    func testLosingContactDoesNotRetractAnUnreadResult() {
        XCTAssertEqual(
            AgentPresentation.bucket(state: .unknown, hasPendingRequest: false, hasUnread: true),
            .unread)
    }

    /// There is deliberately nowhere to PUT a bucket. A bucket enum has no
    /// ordinal, and storing one destroys the read-state model, which is two
    /// monotonic watermarks over an append-only log. This test is the tripwire:
    /// if a bucket ever becomes a stored property of a session, it fails.
    func testASessionCarriesNoStoredBucket() {
        let mirror = Mirror(reflecting: AgentSession(id: "a", provider: "p"))
        let names = mirror.children.compactMap(\.label)
        XCTAssertFalse(names.contains { $0.lowercased().contains("bucket") },
                       "a presentation bucket became stored state: \(names)")
        XCTAssertFalse(names.contains { $0.lowercased().contains("presentation") },
                       "a presentation bucket became stored state: \(names)")
    }

    // MARK: - Outcomes carry the truth

    /// A boolean would mean refused, unsupported and failed all at once.
    func testSendOutcomeDistinguishesRefusedFromUnsupportedFromFailed() {
        XCTAssertNotEqual(SendOutcome.busy, .unsupported)
        XCTAssertNotEqual(SendOutcome.failed(reason: "500"), .unsupported)
        XCTAssertEqual(SendOutcome.failed(reason: "500"), .failed(reason: "500"))
    }

    /// ACP's permission vocabulary, plus `other` so this is not a
    /// permission-only model: a plan choice and a branch name are requests too.
    func testTheOptionKindsCoverACPsPermissionVocabularyAndOneEscapeHatch() {
        XCTAssertEqual(Set(["allow_once", "allow_always", "reject_once", "reject_always",
                            "other"]),
                       Set([PendingRequest.Option.Kind.allowOnce, .allowAlways, .rejectOnce,
                            .rejectAlways, .other].map(\.rawValue)))
    }
}
