import XCTest
@testable import TranquilityCore

/// A remote change becomes a line in the spool the hooks already write, and
/// everything downstream is unchanged. These pin what does and does not earn
/// a line, because a spool line is a sentence spoken out loud.
final class RemoteSpoolTests: XCTestCase {

    private let at = Date(timeIntervalSince1970: 1_757_000_000)
    private func agent(_ raw: String = "s1", state: AgentSessionState = .working,
                       repository: String? = "acme/importer") -> AgentSession {
        var s = AgentSession.of(raw, provider: "opencode", state: state, updatedAt: at)
        s.repository = repository
        return s
    }
    private func event(_ kind: AgentEvent.Kind, session: String = "s1") -> AgentEvent {
        AgentEvent(provider: "opencode",
                   session: AgentSession.id(session, provider: "opencode"), at: at, kind: kind)
    }

    // MARK: - What earns a line

    func testWhatTheAgentSaidBecomesAStopLine() {
        let turn = Turn(id: "t1", at: at, role: .agent, text: "Cleaning up.")
        let lines = RemoteSpool.lines(for: event(.said(turn)), agent: agent())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].hookEvent, .stop)
        XCTAssertEqual(lines[0].lastAssistantMessage, "Cleaning up.")
    }

    /// A user message echoed back is already in the log by the route that sent
    /// it; storing it again announces the user's own sentence to them.
    func testTheUsersOwnWordsAreNotSpooledBack() {
        let turn = Turn(id: "t1", at: at, role: .user, text: "do the thing")
        XCTAssertTrue(RemoteSpool.lines(for: event(.said(turn)), agent: agent()).isEmpty)
    }

    /// A question is a TURN (a Stop line), because the answer goes through
    /// this app: only a Stop is waiting, unread, announced, and a reply
    /// target. As a Notification it was none of those (15 Sep, 5:20 PM). The
    /// matcher still says why.
    func testAQuestionIsATurnCarryingWhyAndTheChoices() {
        let request = PendingRequest(id: "q", session: agent().id, asked: "Run cat hq.json?",
                                     options: [.init(id: "allow_once", label: "Allow once", kind: .allowOnce),
                                               .init(id: "reject_once", label: "Reject", kind: .rejectOnce)])
        let lines = RemoteSpool.lines(for: event(.asks(request)), agent: agent())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].hookEvent, .stop)
        XCTAssertEqual(lines[0].notificationMatcher, "agent_question")
        XCTAssertEqual(lines[0].lastAssistantMessage,
                       "The agent is asking permission: Run cat hq.json?. Options: Allow once, Reject.")
        let own = PendingRequest(id: "q2", session: agent().id, asked: "How deep?",
                                 options: [.init(id: "Thorough", label: "Thorough"), .init(id: "Quick", label: "Quick")])
        XCTAssertEqual(RemoteSpool.lines(for: event(.asks(own)), agent: agent())[0].lastAssistantMessage,
                       "The agent is asking: How deep?. Options: Thorough, Quick.", "the agent's own question is not a permission")
    }


    /// The decision the card shows: the ask verbatim, the choices as the proposal.
    /// A question this app still holds is closed by an answer given elsewhere,
    /// or by the agent coming back with no request (the ask died with the
    /// process). Closed means dismissed, never replaced by a templated turn.
    func testAQuestionIsClosedByAnAnswerOrByComingBackWithoutOne() {
        let adopted = agent(state: .completed)
        let asked = WaitingSession(sessionId: adopted.id, latestId: 9, createdAtMs: 1_000,
                                   lastAssistantMessage: "The agent is asking permission: x",
                                   notificationMatcher: "agent_question", hookEvent: .stop)
        let open = PendingRequest(id: "q", session: adopted.id, asked: "x?")
        XCTAssertTrue(RemoteSpool.closesQuestion(event(.appeared(adopted)), pending: nil, latest: asked))
        XCTAssertFalse(RemoteSpool.closesQuestion(event(.appeared(adopted)), pending: open, latest: asked),
                       "the ask survived; it stays open and amber")
        XCTAssertTrue(RemoteSpool.closesQuestion(event(.answered(requestId: "q")), pending: nil, latest: asked))
        XCTAssertFalse(RemoteSpool.closesQuestion(event(.changed(adopted)), pending: nil, latest: asked),
                       "a live change is not a restart")
        let finished = WaitingSession(sessionId: adopted.id, latestId: 9, createdAtMs: 1_000,
                                      lastAssistantMessage: "Done.", hookEvent: .stop)
        XCTAssertFalse(RemoteSpool.closesQuestion(event(.appeared(adopted)), pending: nil, latest: finished),
                       "nothing to close when the last word was not a question")
    }

    func testAQuestionsBriefIsTheDecisionNotASummary() {
        let words = "The agent is asking permission: Read ~/Downloads/x.png. Options: Allow once, Always allow, Reject."
        let brief = RemoteSpool.decision(from: words, projectLabel: "toy")
        XCTAssertEqual(brief.topic, "Permission")
        XCTAssertEqual(brief.recap, "The agent is asking permission: Read ~/Downloads/x.png.")
        XCTAssertEqual(brief.proposal, "Allow once, Always allow, Reject. Which?")
    }

    /// **The one that is easy to miss.** The green lamp comes from an
    /// undismissed stop event in the local database, not from the provider's
    /// verdict. Without this line a finished remote agent has nothing for the
    /// grid to find and the row never goes green, however correct the state is.
    func testATurnThatEndedWritesAStopEventOrTheLampNeverLights() {
        for state in [AgentSessionState.completed, .failed, .canceled, .rejected] {
            var finished = agent(state: state)
            finished.state = state
            let lines = RemoteSpool.lines(for: event(.changed(finished)), agent: finished)
            XCTAssertEqual(lines.count, 1, "\(state.rawValue) wrote no turn-ended event")
            XCTAssertEqual(lines[0].hookEvent, .stop)
        }
    }

    /// **Only the transition is a turn.** A change while already finished (a
    /// title arriving, a list re-read) wrote a bare stop line AFTER the words,
    /// and the announcer reads a session's latest: Robert's first OpenCode
    /// turn was spoken as "finished a turn" (15 Sep). The poller stamps what
    /// it knew before; unknown fails open.
    func testAChangeWhileAlreadyFinishedIsNotASecondTurn() {
        var finished = agent(state: .completed)
        finished.title = "Recent work recap"
        var again = event(.changed(finished))
        again.previously = .completed
        XCTAssertEqual(RemoteSpool.lines(for: again, agent: finished), [])

        var ending = event(.changed(finished))
        ending.previously = .working
        XCTAssertEqual(RemoteSpool.lines(for: ending, agent: finished).count, 1)

        let unknown = event(.changed(finished))
        XCTAssertEqual(RemoteSpool.lines(for: unknown, agent: finished).count, 1,
                       "with no memory of before, the ending is written rather than lost")
    }

    func testAFailureCarriesItsReason() {
        let lines = RemoteSpool.lines(for: event(.failed(reason: "the sandbox died")),
                                      agent: agent())
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].lastAssistantMessage?.contains("the sandbox died") == true)
    }

    // MARK: - What does not

    /// Writing these would move the read-state watermark past content nobody
    /// has seen, which is the grid going quiet while the agent is still asking.
    func testNewsThatIsNotNewsWritesNothing() {
        XCTAssertTrue(RemoteSpool.lines(for: event(.appeared(agent())), agent: agent()).isEmpty)
        XCTAssertTrue(RemoteSpool.lines(for: event(.answered(requestId: "q")),
                                        agent: agent()).isEmpty)
        // Working is a state the row already shows; speaking every transition
        // would narrate the agent's whole life.
        XCTAssertTrue(RemoteSpool.lines(for: event(.changed(agent(state: .working))),
                                        agent: agent()).isEmpty)
    }

    // MARK: - Identity

    /// The drainer dedupes on the record id, so the same change seen twice by
    /// a retry, a restart or an overlapping tick must produce the same id or
    /// the agent says everything twice.
    func testTheSameChangeTwiceIsTheSameLine() {
        let turn = Turn(id: "t1", at: at, role: .agent, text: "Cleaning up.")
        let a = RemoteSpool.lines(for: event(.said(turn)), agent: agent())[0]
        let b = RemoteSpool.lines(for: event(.said(turn)), agent: agent())[0]
        XCTAssertEqual(a.id, b.id)
    }

    func testDifferentWordsAreDifferentLines() {
        let one = Turn(id: "t1", at: at, role: .agent, text: "one")
        let two = Turn(id: "t1", at: at, role: .agent, text: "two")
        XCTAssertNotEqual(RemoteSpool.lines(for: event(.said(one)), agent: agent())[0].id,
                          RemoteSpool.lines(for: event(.said(two)), agent: agent())[0].id)
    }

    // MARK: - The wire shape

    /// `projectLabel` reads the last path component of `cwd`, and that label is
    /// what a row and a spoken line call this agent. "importer" beats eight hex
    /// characters.
    func testTheRepositoryStandsInForAWorkingDirectorySoTheRowHasAName() {
        let turn = Turn(id: "t1", at: at, role: .agent, text: "done")
        let line = RemoteSpool.lines(for: event(.said(turn)), agent: agent())[0]
        XCTAssertEqual(line.cwd, "acme/importer")

        let stored = QueuedEvent(hookEvent: .stop, sessionId: line.sessionId, cwd: line.cwd)
        XCTAssertEqual(stored.projectLabel, "importer")
    }

    /// A provider with no repository must not invent one; projectLabel already
    /// falls back to the id.
    func testAProviderWithNoRepositoryWritesNoDirectory() {
        let turn = Turn(id: "t1", at: at, role: .agent, text: "done")
        let line = RemoteSpool.lines(for: event(.said(turn)),
                                     agent: agent(repository: nil))[0]
        XCTAssertNil(line.cwd)
    }

    /// Local facts a remote agent does not have are ABSENT, not empty. An empty
    /// string reads as a path that failed rather than one that does not exist.
    func testLocalOnlyFieldsAreOmittedRatherThanBlank() {
        let turn = Turn(id: "t1", at: at, role: .agent, text: "done")
        let json = RemoteSpool.lines(for: event(.said(turn)), agent: agent())[0].json()
        XCTAssertNil(json["transcriptPath"])
        XCTAssertNil(json["tty"])
        XCTAssertNotNil(json["sessionId"])
    }

    // MARK: - Through the real drainer, which is the point

    /// The whole claim of #372 is that a remote line needs NO new code
    /// downstream. This proves it by running one through `SpoolDrainer` and
    /// reading the stored event back.
    func testARemoteLineFlowsThroughTheExistingDrainerUntouched() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try QueueStore(url: dir.appendingPathComponent("q.sqlite"))
        let spool = dir.appendingPathComponent("spool.jsonl")

        let turn = Turn(id: "t1", at: at, role: .agent, text: "Cleaning up.")
        let written = RemoteSpool.append(
            RemoteSpool.lines(for: event(.said(turn)), agent: agent()), to: spool)
        XCTAssertEqual(written, 1)

        let result = try SpoolDrainer(store: store, spoolURL: spool).drain()
        XCTAssertEqual(result.inserted, 1)
        XCTAssertEqual(result.malformed, 0, "the existing decoder rejected a remote line")

        let known = try store.allKnownSessions()
        XCTAssertEqual(known.first?.sessionId, agent().id)
        XCTAssertEqual(known.first?.lastAssistantMessage, "Cleaning up.")
        XCTAssertEqual(known.first?.projectLabel, "importer")
    }

    /// Replaying the same line is harmless, which is what lets a poller be
    /// careless about retries.
    func testReplayingALineInsertsItOnce() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try QueueStore(url: dir.appendingPathComponent("q.sqlite"))
        let spool = dir.appendingPathComponent("spool.jsonl")

        let turn = Turn(id: "t1", at: at, role: .agent, text: "Cleaning up.")
        let lines = RemoteSpool.lines(for: event(.said(turn)), agent: agent())
        RemoteSpool.append(lines, to: spool)
        _ = try SpoolDrainer(store: store, spoolURL: spool).drain()
        RemoteSpool.append(lines, to: spool)
        let second = try SpoolDrainer(store: store, spoolURL: spool).drain()

        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.duplicates, 1, "the same change twice must not speak twice")
    }

    /// The hook appends to this file from inside a live turn and cannot take a
    /// lock. A writer that rewrote it would lose whatever landed in between.
    func testWritingAppendsRatherThanReplacing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remote-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = dir.appendingPathComponent("spool.jsonl")
        try #"{"id":"local","createdAtMs":1,"hookEvent":"Stop","sessionId":"abc"}"#
            .appending("\n").write(to: spool, atomically: true, encoding: .utf8)

        let turn = Turn(id: "t1", at: at, role: .agent, text: "Cleaning up.")
        RemoteSpool.append(RemoteSpool.lines(for: event(.said(turn)), agent: agent()), to: spool)

        let text = try String(contentsOf: spool, encoding: .utf8)
        XCTAssertTrue(text.contains("\"id\":\"local\""), "the hook's line was clobbered")
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }
}
