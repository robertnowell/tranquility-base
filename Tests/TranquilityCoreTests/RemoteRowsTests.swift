import XCTest
@testable import TranquilityCore

/// A remote agent is an ordinary row. These mostly prove a negative: that
/// nothing below the fifth band asks what kind of agent a row is.
final class RemoteRowsTests: XCTestCase {

    private func remote(_ raw: String, state: AgentSessionState = .working,
                        title: String = "", repository: String? = nil,
                        url: URL? = nil) -> AgentSession {
        var s = AgentSession.of(raw, provider: "crobot", title: title, state: state)
        s.repository = repository
        s.url = url
        return s
    }

    private func rows(_ remote: GridAssembler.RowInputs.RemoteAgents,
                      switchedOff: Set<String> = []) -> [SessionRow] {
        GridAssembler.rows(GridAssembler.RowInputs(
            waiting: [], known: [], discovered: [], liveById: [:], boundaries: [:],
            switchedOff: switchedOff, switchedOn: [],
            evidence: { _, _ in nil }, isHeadless: { _ in false }, family: { [$0] },
            supersedesWaiting: { _, _ in false }, isInFlight: { _ in false },
            remote: remote)).rows
    }

    // MARK: - Lamps

    func testABlockedAgentIsAmberAndSpendsItsColumnOnTheQuestion() {
        let agent = remote("a", state: .inputRequired)
        let out = rows(.init(agents: [agent],
                             requests: [agent.id: PendingRequest(
                                id: "q", session: agent.id, asked: "Merge to main?")]))
        XCTAssertEqual(out.first?.lamp, .fault)
        XCTAssertEqual(out.first?.aux, "Merge to main?")
    }

    func testSomethingUnreadIsGreenAndReadsAsUnread() {
        let agent = remote("a", state: .completed)
        let out = rows(.init(agents: [agent], unread: [agent.id]))
        XCTAssertEqual(out.first?.lamp, .ready)
        XCTAssertEqual(out.first?.read, .unread)
    }

    func testAFinishedAgentNobodyOwesAnythingIsUnlit() {
        let out = rows(.init(agents: [remote("a", state: .completed)]))
        XCTAssertEqual(out.first?.lamp, .unlit)
    }

    func testAWorkingAgentIsBlue() {
        XCTAssertEqual(rows(.init(agents: [remote("a", state: .working)])).first?.lamp, .working)
    }

    /// **The rule the poller exists to protect.** A provider that cannot be
    /// reached must not leave a row looking calm, and the words carry what a
    /// colour cannot say.
    func testAnUnreachableProviderSaysSoRatherThanLookingQuiet() {
        let agent = remote("a", state: .unknown)
        let out = rows(.init(agents: [agent], unreachable: ["crobot": "the wire is down"]))
        XCTAssertEqual(out.first?.aux, "cannot reach it")
        XCTAssertTrue(out.first?.detail?.contains("the wire is down") == true,
                      "the provider's own reason belongs in the hover")
    }

    /// A blocked agent outranks everything, exactly as on the local bands.
    func testABlockingRequestOutranksUnread() {
        let agent = remote("a", state: .working)
        let out = rows(.init(agents: [agent],
                             requests: [agent.id: PendingRequest(id: "q", session: agent.id,
                                                                 asked: "?")],
                             unread: [agent.id]))
        XCTAssertEqual(out.first?.lamp, .fault)
    }

    // MARK: - The door

    /// Go to Agent is the same verb to the user. Only the destination differs,
    /// and it differs because the ROW says so, never because something asked
    /// what kind of agent it was.
    func testAnAgentWithAPageOpensItRatherThanAPane() {
        let url = URL(string: "https://crobot.example.test/tasks/a")!
        let out = rows(.init(agents: [remote("a", state: .working, url: url)]))
        XCTAssertEqual(SessionRow.action(for: out[0]), .openPage(url))
        XCTAssertTrue(SessionRow.isLive(out[0]), "an agent you can open is an agent that exists")
    }

    /// A local `opencode serve` has no web page and no pane of ours. Offering
    /// a door that opens on nothing reads as broken rather than as absent.
    func testAnAgentWithNeitherDoorOffersNothing() {
        let out = rows(.init(agents: [remote("a", state: .working, url: nil)]))
        XCTAssertEqual(SessionRow.action(for: out[0]), SessionRow.RowAction.none)
    }

    /// Every local row keeps the door it always had, which is what makes this
    /// a default rather than a migration.
    func testALocalRowStillGoesToItsTerminal() {
        let local = SessionRow(id: "l", name: "n", aux: "a", lamp: .working)
        XCTAssertEqual(local.door, .terminal)
        XCTAssertEqual(SessionRow.action(for: local), .goToAgent)
    }

    // MARK: - Naming

    /// The provider's own title beats anything this app can derive, same
    /// precedence as every other band.
    func testTheProvidersTitleWinsThenTheRepositoryThenTheId() {
        XCTAssertEqual(rows(.init(agents: [remote("a", title: "port the importer",
                                                  repository: "acme/importer")])).first?.name,
                       "port the importer")
        XCTAssertEqual(rows(.init(agents: [remote("a", repository: "acme/importer")])).first?.name,
                       "acme/importer")
        let bare = rows(.init(agents: [remote("a")])).first
        XCTAssertEqual(bare?.name, SessionRow.shortId(bare!.id))
    }

    /// A request can carry several questions and answering needs all of them.
    /// The column shows one clause; the hover is where the rest lives.
    func testEveryQuestionReachesTheHoverNotJustTheFirst() {
        let agent = remote("a", state: .inputRequired)
        let request = PendingRequest(id: "q", session: agent.id, questions: [
            .init(asked: "Which branch?"), .init(asked: "Squash or merge?"),
        ])
        let out = rows(.init(agents: [agent], requests: [agent.id: request]))
        XCTAssertEqual(out.first?.detail, "Which branch?\nSquash or merge?")
    }

    // MARK: - It is an ordinary row

    /// The claim of this issue, stated as a test: every rule below the band
    /// applies, and none of them asks what kind of agent this is.
    func testTheUsersFiledLampAppliesToARemoteRowToo() {
        let agent = remote("a", state: .working)
        let out = rows(.init(agents: [agent]), switchedOff: [agent.id])
        XCTAssertTrue(out.first?.switchedOff == true)
        XCTAssertEqual(out.first?.lamp, .running)
    }

    /// The SHARED rule, and the assertion is deliberately about peers.
    ///
    /// `quietRowsLast` ranks ready, working and fault together at the top and
    /// keeps their arrival order; only merely-alive and dead rows sink. So a
    /// blocked remote agent does NOT jump above a working one, exactly as a
    /// blocked local session does not. That is the point: the fifth band is
    /// subject to the same ordering as the other four, including the parts
    /// somebody might expect to work differently.
    func testRemoteRowsObeyTheSameOrderingAsLocalOnes() {
        let asking = remote("asking", state: .inputRequired)
        let working = remote("working", state: .working)
        let done = remote("done", state: .completed)
        let out = rows(.init(agents: [done, working, asking],
                             requests: [asking.id: PendingRequest(id: "q", session: asking.id,
                                                                  asked: "?")]))
        XCTAssertEqual(out.map(\.lamp), [.working, .fault, .unlit],
                       "lit rows keep arrival order; only the dead sink")
        XCTAssertEqual(out.map(\.lamp), SessionRow.quietRowsLast(out).map(\.lamp),
                       "and the band is already in the shared rule's order")
    }

    /// One row per agent, and a local band that already placed an id wins,
    /// exactly as the local bands do among themselves.
    func testAnIdAlreadyPlacedLocallyIsNotDuplicatedByTheRemoteBand() {
        let id = "8f14e45f-ceea-467a-9eef-2b9c1b2dc9f0"
        var w = WaitingSession(sessionId: id, latestId: 1, createdAtMs: 0, hookEvent: .stop)
        w.heardThrough = nil
        var agent = AgentSession.of(id, provider: "crobot", state: .working)
        agent.url = nil
        let out = GridAssembler.rows(GridAssembler.RowInputs(
            waiting: [w], known: [], discovered: [], liveById: [:], boundaries: [:],
            switchedOff: [], switchedOn: [],
            evidence: { _, _ in nil }, isHeadless: { _ in false }, family: { [$0] },
            supersedesWaiting: { _, _ in false }, isInFlight: { _ in false },
            remote: .init(agents: [agent]))).rows
        XCTAssertEqual(out.filter { $0.id == id }.count, 1)
    }
}
