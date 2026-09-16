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

    /// **A pending permission is AMBER** (revised 15 Sep 7:47 PM; a question
    /// that ends a turn is still green, 14 Sep). The agent is blocked on it
    /// the way a local agent is blocked on a dialog, and local dialogs are
    /// amber with the reason in the column. Robert: "it seems hung, and the
    /// lamp is not amber, and there is no decision or anything."
    func testAnAgentBlockedOnAPermissionIsAmberAndSpendsItsColumnOnTheQuestion() {
        let agent = remote("a", state: .inputRequired)
        let out = rows(.init(agents: [agent],
                             requests: [agent.id: PendingRequest(
                                id: "q", session: agent.id, asked: "Merge to main?")]))
        XCTAssertEqual(out.first?.lamp, .fault)
        XCTAssertEqual(out.first?.aux, "Merge to main?")
        XCTAssertEqual(out.first?.read, .unread, "unread until answered, so the tap brings the decision back")
    }

    func testSomethingUnreadIsGreenAndReadsAsUnread() {
        let agent = remote("a", state: .completed)
        let out = rows(.init(agents: [agent], unread: [agent.id]))
        XCTAssertEqual(out.first?.lamp, .ready)
        XCTAssertEqual(out.first?.read, .unread)
    }

    /// **A finished turn is GREEN, read or unread.** The unlit socket is
    /// reachable only through the user's own switch or a dead process, so a
    /// remote agent that simply finished cannot land there. This assertion is
    /// the one that was keeping every crobot task off the panel: `idle` became
    /// `.completed` became unlit became unsorted became invisible.
    func testAFinishedAgentIsGreenEvenWithNothingUnread() {
        let out = rows(.init(agents: [remote("a", state: .completed)]))
        XCTAssertEqual(out.first?.lamp, .ready)
        XCTAssertEqual(out.first?.read, ReadState.none,
                       "green without unread is still not unread")
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
        XCTAssertEqual(out.first?.lamp, .fault, "silence is amber, never calm")
        XCTAssertEqual(out.first?.aux, "cannot reach it")
        XCTAssertTrue(out.first?.detail?.contains("the wire is down") == true,
                      "the provider's own reason belongs in the hover")
    }

    /// A question outranks blue, exactly as on the local bands: an agent that
    /// is nominally still working but has stopped to ask is YOUR turn, and
    /// advisory blue must not mask it.
    func testAQuestionOutranksWorking() {
        let agent = remote("a", state: .working)
        let out = rows(.init(agents: [agent],
                             requests: [agent.id: PendingRequest(id: "q", session: agent.id,
                                                                 asked: "?")],
                             unread: [agent.id]))
        XCTAssertEqual(out.first?.lamp, .fault, "a permission outranks working, and it is amber")
    }

    /// **The tripwire.** Three lamps light a remote row and there is no fourth:
    /// no quiet socket, no unlit. Measured 14 Sep, the retired quiet lamp was
    /// worn by 23 rows and every one of them came from this band.
    func testARemoteRowOnlyEverDrawsOneOfThreeLamps() {
        let states: [AgentSessionState] = [
            .submitted, .working, .inputRequired, .authRequired,
            .failed, .completed, .canceled, .rejected, .unknown,
        ]
        var seen: Set<Lamp> = []
        for state in states {
            seen.formUnion(rows(.init(agents: [remote("a", state: state)])).map(\.lamp))
        }
        XCTAssertEqual(seen, [.ready, .working, .fault],
                       "a remote row drew a lamp outside the three: \(seen)")
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
        XCTAssertEqual(out.first?.lamp, .running,
                       "the user's switch is the ONE route to a quiet lamp, and it is "
                       + "the same route for a remote row as for a local one")
    }

    /// The SHARED rule, and the assertion is deliberately about peers.
    ///
    /// `quietRowsLast` ranks the lamps that ask for you (green, amber) above
    /// blue, and each tier by recency (ruled 15 Sep); only merely-alive and
    /// dead rows sink below all of them. So a working remote agent sits under
    /// a finished one, exactly as a working local session does. That is the
    /// point: the fifth band is subject to the same ordering as the other
    /// four, including the parts somebody might expect to work differently.
    func testRemoteRowsObeyTheSameOrderingAsLocalOnes() {
        let asking = remote("asking", state: .inputRequired)
        let working = remote("working", state: .working)
        let done = remote("done", state: .completed)
        let out = rows(.init(agents: [done, working, asking],
                             requests: [asking.id: PendingRequest(id: "q", session: asking.id,
                                                                  asked: "?")]))
        XCTAssertEqual(out.map(\.lamp), [.ready, .fault, .working],
                       "green and amber above blue, and under the three-lamp ruling "
                       + "a finished agent is lit rather than sunk")
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

// MARK: - A green remote row is clickable (14 Sep)

extension RemoteRowsTests {

    /// **The no-op.** Announce reads a finished turn out of the LOCAL store,
    /// so it is the right verb only for a row that has one. A remote agent has
    /// no local transcript and no local id, so the announce path guarded on a
    /// lookup that could never succeed and returned in silence: the click did
    /// nothing at all, which is worse than a control that refuses.
    ///
    /// Latent until the three-lamp ruling. Remote rows used to be unlit or
    /// quiet, so `goTo` was only reachable through the other three lamps;
    /// making them green stranded the door they were already carrying.
    func testAGreenRemoteRowOpensItsPageRatherThanAnnouncingNothing() {
        var agent = remote("a", state: .completed)
        agent.url = URL(string: "https://crobot.example/task/a")
        let row = rows(.init(agents: [agent])).first
        XCTAssertEqual(row?.lamp, .ready)
        XCTAssertEqual(SessionRow.action(for: row!),
                       .openPage(URL(string: "https://crobot.example/task/a")!))
    }

    /// And a green LOCAL row still announces, which is the app's daily loop
    /// and must not have been traded away for the fix above. A local green row
    /// always carries a read state — band 1 stamps one — which is what makes
    /// announce meaningful.
    func testAGreenLocalRowStillAnnounces() {
        let local = SessionRow(id: "local", name: "n", aux: "a", lamp: .ready, read: .unread)
        XCTAssertEqual(SessionRow.action(for: local), .announce)
    }

    /// A green remote agent with NO page still announces, and that is right
    /// rather than a leftover: a remote change arrives as a line in
    /// `spool.jsonl` and drains into the local store like any other, so there
    /// genuinely is something to read back. Local OpenCode is exactly this
    /// case — a real agent, no web page, and its results still reach the card.
    ///
    /// So the door decides only whether there is somewhere BETTER to go, and
    /// announce stays the fallback rather than being traded away.
    func testAGreenRemoteAgentWithNoPageStillAnnounces() {
        let agent = remote("a", state: .completed)
        let row = rows(.init(agents: [agent], unread: [agent.id])).first
        XCTAssertEqual(row?.door, SessionRow.Door.none)
        XCTAssertEqual(SessionRow.action(for: row!), .announce)
    }

    /// **And one that has never spoken does nothing rather than announcing
    /// nothing.** Robert, 15 Sep, on twenty-nine such rows in Past Agents:
    /// "clicking on them does nothing. It's very weird that they're there."
    /// They were probe sessions that had finished a turn (green, correctly)
    /// and never written a line to the store (nothing to announce). The verb
    /// says so now instead of pretending.
    func testAGreenRemoteAgentThatNeverSpokeDoesNotAnnounce() {
        let row = rows(.init(agents: [remote("a", state: .completed)])).first
        XCTAssertEqual(row?.read, ReadState.none)
        XCTAssertEqual(SessionRow.action(for: row!), SessionRow.RowAction.none,
                       "announce would read a turn that does not exist")
    }
}
