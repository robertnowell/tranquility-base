import XCTest
@testable import TranquilityCore

/// A launch is a turn (ruled 18 Aug). Starting an agent used to open a Terminal
/// window and stop there; now the app writes the session's first card itself, so
/// the loop that answers every other agent answers this one too.
///
/// What these tests hold is the architecture, not the wording: a greeting is one
/// event and one brief for the REAL session id, written together, and it is
/// never sent to the agent.
final class LaunchGreetingTests: XCTestCase {
    var tmpDir: URL!
    var store: QueueStore!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-greeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = try QueueStore(url: tmpDir.appendingPathComponent("queue.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// `claude agents --json`, on a schedule of our choosing. `nil` is the probe
    /// failing to answer, which is not the same as nobody being there.
    final class ScriptedAgents: ClaudeAgentsReading, @unchecked Sendable {
        private var answers: [[LiveSession]?]
        private(set) var calls = 0
        init(_ answers: [[LiveSession]?]) { self.answers = answers }
        func sessions() -> [LiveSession]? {
            calls += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private func live(_ id: String, cwd: String) -> LiveSession {
        LiveSession(pid: 1, sessionId: id, cwd: cwd, status: nil, name: nil, waitingFor: nil)
    }

    // MARK: - The turn

    func testGreetingMakesTheSessionWaitingWithWordsOnItsCard() throws {
        let rowid = try XCTUnwrap(LaunchGreeting.record(
            sessionId: "s1", directory: "/Users/x/Projects/kopi", store: store))

        let waiting = try store.waitingSessions()
        XCTAssertEqual(waiting.map(\.sessionId), ["s1"])
        // The brief is keyed by the rowid the waiting query reports — the exact
        // identity `Coordinator.restoredSummary` looks a brief up by. If these
        // two ever disagree the greeting still shows as waiting and the
        // announcer pays for a model call to describe an empty transcript.
        XCTAssertEqual(waiting.first?.latestId, rowid)
        let brief = try XCTUnwrap(store.storedBrief(sessionId: "s1", eventRowid: rowid))
        XCTAssertEqual(brief.question, LaunchGreeting.question)
        XCTAssertEqual(brief.provider, LaunchGreeting.provider)
        // Named by where it is, since that is the only true thing about a
        // session that has not done anything yet.
        XCTAssertTrue(brief.happened.contains("kopi"), brief.happened)
        // Spoken, it opens with what it is and closes on the question.
        XCTAssertTrue(brief.brief.spokenText().hasSuffix(LaunchGreeting.question))
    }

    /// The greeting is the app talking about the session, never to it.
    func testGreetingFabricatesNoTranscript() throws {
        let rowid = try XCTUnwrap(LaunchGreeting.record(
            sessionId: "s1", directory: "/Users/x/Projects/kopi", store: store))
        let event = try XCTUnwrap(store.events().first { $0.sessionId == "s1" })
        XCTAssertNil(event.transcriptPath)
        XCTAssertNil(event.lastAssistantMessage)
        XCTAssertNil(event.summaryText)
        XCTAssertEqual(try store.storedBrief(sessionId: "s1", eventRowid: rowid)?.sessionId, "s1")
    }

    /// A second call writes nothing: one launch, one greeting, whatever retries
    /// happen above it.
    func testGreetingIsRecordedOnce() throws {
        XCTAssertNotNil(try LaunchGreeting.record(
            sessionId: "s1", directory: "/tmp/one", store: store))
        XCTAssertNil(try LaunchGreeting.record(
            sessionId: "s1", directory: "/tmp/one", store: store))
        XCTAssertEqual(try store.waitingSessions().count, 1)
    }

    /// Two agents started in the same directory are two agents.
    func testEachSessionGetsItsOwnGreeting() throws {
        _ = try LaunchGreeting.record(sessionId: "s1", directory: "/tmp/one", store: store)
        _ = try LaunchGreeting.record(sessionId: "s2", directory: "/tmp/one", store: store)
        XCTAssertEqual(Set(try store.waitingSessions().map(\.sessionId)), ["s1", "s2"])
    }

    // MARK: - Waiting for the session to register

    func testRegistrationTakesTheFirstNewIdInTheLaunchedDirectory() {
        let agents = ScriptedAgents([
            [live("old", cwd: "/tmp/one")],
            [live("old", cwd: "/tmp/one"), live("new", cwd: "/tmp/one")],
        ])
        var clock = Date(timeIntervalSince1970: 0)
        let found = LaunchGreeting.awaitRegistration(
            directory: "/tmp/one", excluding: ["old"], agents: agents,
            now: { clock }, sleep: { clock += $0 })
        XCTAssertEqual(found, "new")
    }

    /// Another window in another project is not our launch.
    func testRegistrationIgnoresOtherDirectories() {
        let agents = ScriptedAgents([[live("elsewhere", cwd: "/tmp/two")]])
        var clock = Date(timeIntervalSince1970: 0)
        let found = LaunchGreeting.awaitRegistration(
            directory: "/tmp/one", excluding: [], agents: agents,
            timeout: 4, interval: 2, now: { clock }, sleep: { clock += $0 })
        XCTAssertNil(found)
    }

    /// A probe that cannot answer is not an answer. Keep waiting.
    func testRegistrationKeepsWaitingThroughAFailingProbe() {
        let agents = ScriptedAgents([nil, nil, [live("new", cwd: "/tmp/one")]])
        var clock = Date(timeIntervalSince1970: 0)
        let found = LaunchGreeting.awaitRegistration(
            directory: "/tmp/one", excluding: [], agents: agents,
            now: { clock }, sleep: { clock += $0 })
        XCTAssertEqual(found, "new")
        XCTAssertEqual(agents.calls, 3)
    }

    /// The trust prompt is never auto-answered, so a launch nobody consented to
    /// simply never registers — and the caller gets nil rather than a greeting
    /// for a session that does not exist.
    func testRegistrationGivesUpAtTheDeadline() {
        let agents = ScriptedAgents([])
        var clock = Date(timeIntervalSince1970: 0)
        let found = LaunchGreeting.awaitRegistration(
            directory: "/tmp/one", excluding: [], agents: agents,
            timeout: 30, interval: 2, now: { clock }, sleep: { clock += $0 })
        XCTAssertNil(found)
        XCTAssertEqual(agents.calls, 15)
    }
}
