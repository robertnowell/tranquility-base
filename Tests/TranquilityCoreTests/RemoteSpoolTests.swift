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

    func testAQuestionBecomesANotificationCarryingWhy() {
        let request = PendingRequest(id: "q", session: agent().id, asked: "Which branch?")
        let lines = RemoteSpool.lines(for: event(.asks(request)), agent: agent())
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].hookEvent, .notification)
        XCTAssertEqual(lines[0].notificationMatcher, "agent_question")
        XCTAssertEqual(lines[0].lastAssistantMessage, "Which branch?")
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
