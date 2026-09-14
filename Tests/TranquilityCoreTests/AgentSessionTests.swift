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

    // MARK: - Three lamps, and there is no fourth (ruled 14 Sep 2026)

    /// > *"Any lamps turned on, that is to say agents that are in the grid, are
    /// > either green, blue, or amber. There's nothing else."*
    ///
    /// The tripwire for the whole ruling. A fourth bucket cannot be added
    /// without this failing, which is the point: the last fourth lamp arrived
    /// by accident, was worn by 23 rows, and every one of them was remote.
    func testEveryStateLandsOnExactlyOneOfThreeLamps() {
        let states: [AgentSessionState] = [
            .submitted, .working, .inputRequired, .authRequired,
            .failed, .completed, .canceled, .rejected, .unknown,
        ]
        var seen: Set<AgentPresentation> = []
        for state in states {
            for pending in [true, false] {
                seen.insert(AgentPresentation.bucket(state: state, hasPendingRequest: pending))
            }
        }
        XCTAssertEqual(seen, [.yours, .working, .problem],
                       "a fourth lamp appeared: \(seen)")
        XCTAssertEqual(Set([GridAssembler.lamp(for: .yours),
                            GridAssembler.lamp(for: .working),
                            GridAssembler.lamp(for: .problem)]),
                       [.ready, .working, .fault],
                       "the three buckets must draw the three lamps")
    }

    /// **A question is GREEN, not amber.** Robert, 14 Sep: *"for something
    /// needs your judgment is great. That's like it needs you. It's your time
    /// to shine."* Amber is reserved for the unanticipated.
    func testAQuestionIsGreenAndAFailureIsAmber() {
        XCTAssertEqual(AgentPresentation.bucket(state: .inputRequired,
                                                hasPendingRequest: false), .yours)
        XCTAssertEqual(AgentPresentation.bucket(state: .working,
                                                hasPendingRequest: true), .yours)
        for broken: AgentSessionState in [.authRequired, .failed, .rejected] {
            XCTAssertEqual(AgentPresentation.bucket(state: broken, hasPendingRequest: false),
                           .problem, "\(broken) is a problem, not a question")
        }
    }

    /// **A vendor's own word `idle` is GREEN.** crobot says `idle` when the
    /// sandbox is up and the turn is over, which is exactly "ready for the next
    /// turn". Mapping it toward the dark end of the panel put an agent's own
    /// state in the position that means *the user switched this off*, and kept
    /// every crobot task off the grid.
    func testAFinishedTurnIsGreenWhetherOrNotAnythingIsUnread() {
        XCTAssertEqual(AgentPresentation.bucket(state: .completed,
                                                hasPendingRequest: false), .yours)
        XCTAssertEqual(AgentPresentation.bucket(state: .canceled,
                                                hasPendingRequest: false), .yours)
    }

    /// **Read-state is not an input to the lamp.** It orders rows and it bolds
    /// them; it never colours one. Making unread a precondition for green is
    /// the defect this signature change exists to make unrepresentable — there
    /// is no longer a parameter to pass it through.
    func testTheLampCannotSeeReadState() {
        let takesUnread = "\(AgentPresentation.bucket)".contains("Bool, Bool")
        XCTAssertFalse(takesUnread,
                       "bucket() regained a second Bool; read-state is leaking into the lamp")
    }

    /// An unreachable provider's agents are AMBER, not quiet. Folding them into
    /// a calm lamp made a captive portal render as a grid of calm agents, with
    /// every lamp lying by omission (13 Sep). The 14 Sep ruling keeps the
    /// distinction and moves it to the channel that actually means *fix this*.
    func testSilenceIsAProblemAndNotAFinishedTurn() {
        XCTAssertEqual(AgentPresentation.bucket(state: .unknown,
                                                hasPendingRequest: false), .problem)
        XCTAssertNotEqual(AgentPresentation.bucket(state: .unknown, hasPendingRequest: false),
                          AgentPresentation.bucket(state: .completed, hasPendingRequest: false),
                          "silence must not read as finished")
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
