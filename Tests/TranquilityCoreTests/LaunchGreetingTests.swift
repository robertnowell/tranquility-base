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

    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func live(_ id: String, cwd: String) -> LiveSession {
        LiveSession(pid: 1, sessionId: id, cwd: cwd, status: nil, name: nil, waitingFor: nil)
    }

    // MARK: - The turn

    func testGreetingMakesTheSessionWaitingWithWordsOnItsCard() throws {
        let line = LaunchGreeting.lines[0]
        let rowid = try XCTUnwrap(LaunchGreeting.record(
            sessionId: "s1", directory: "/Users/x/Projects/kopi", line: line, store: store))

        let waiting = try store.waitingSessions()
        XCTAssertEqual(waiting.map(\.sessionId), ["s1"])
        // The brief is keyed by the rowid the waiting query reports — the exact
        // identity `Coordinator.restoredSummary` looks a brief up by. If these
        // two ever disagree the greeting still shows as waiting and the
        // announcer pays for a model call to describe an empty transcript.
        XCTAssertEqual(waiting.first?.latestId, rowid)
        let brief = try XCTUnwrap(store.storedBrief(sessionId: "s1", eventRowid: rowid))
        XCTAssertEqual(brief.provider, LaunchGreeting.provider)
        // The spoken line is the question and NOTHING else — no project label,
        // no "new agent", no narration of what you just did. Two or three
        // seconds of audio, which is the whole ruling.
        XCTAssertEqual(brief.brief.spokenText(), line)
    }

    /// Two launches in a row do not sound identical.
    func testTheLineAlternates() {
        let first = LaunchGreeting.nextLine()
        let second = LaunchGreeting.nextLine()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(LaunchGreeting.lines.contains(first))
        XCTAssertTrue(LaunchGreeting.lines.contains(second))
        // Short enough to be over before you have thought about it.
        for line in LaunchGreeting.lines {
            XCTAssertLessThanOrEqual(line.split(separator: " ").count, 7, line)
        }
    }

    /// The bug that shipped: a greeting with no transcript path is a reply that
    /// can never be confirmed, because delivery is verified by watching our own
    /// text appear in the transcript. The first message to a new agent landed
    /// correctly and reported "couldn't confirm it landed."
    func testTheGreetingCarriesTheTranscriptSoAReplyCanBeVerified() throws {
        let projects = tmpDir.appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("-Users-x-Projects-kopi")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("s1.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        _ = try LaunchGreeting.record(sessionId: "s1", directory: "/Users/x/Projects/kopi",
                                      line: "a", store: store, projects: projects)
        let waiting = try XCTUnwrap(store.waitingSessions().first)
        // Resolved on both sides: the temp directory is reached through a
        // symlink (/var -> /private/var) and the scan returns the real path.
        XCTAssertEqual(waiting.transcriptPath.map(resolved), resolved(transcript.path))
    }

    /// Found by id rather than derived from the cwd: the directory name is
    /// somebody else's encoding of a path, and reproducing it here is a copy
    /// that fails silently the day it changes.
    func testTheTranscriptIsFoundByIdAcrossProjects() throws {
        let projects = tmpDir.appendingPathComponent("projects", isDirectory: true)
        for name in ["-Users-x-one", "-Users-x-two"] {
            try FileManager.default.createDirectory(
                at: projects.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let wanted = projects.appendingPathComponent("-Users-x-two/abc.jsonl")
        try Data("{}\n".utf8).write(to: wanted)
        XCTAssertEqual(
            TranscriptArchive.transcriptPath(forSessionId: "abc", projects: projects)
                .map(resolved),
            resolved(wanted.path))
        // A session that has registered but not yet written a line is a real
        // state, and nil is the honest answer — the dispatch path resolves it
        // again at send time.
        XCTAssertNil(
            TranscriptArchive.transcriptPath(forSessionId: "nope", projects: projects))
    }

    /// The greeting is the app talking about the session, never to it.
    func testGreetingFabricatesNoTranscript() throws {
        let rowid = try XCTUnwrap(LaunchGreeting.record(
            sessionId: "s1", directory: "/Users/x/Projects/kopi",
            line: LaunchGreeting.lines[0], store: store))
        let event = try XCTUnwrap(store.events().first { $0.sessionId == "s1" })
        // The transcript is POINTED at, never written to: the greeting puts no
        // words in the session's mouth and none in its file.
        XCTAssertNil(event.lastAssistantMessage)
        XCTAssertNil(event.summaryText)
        XCTAssertEqual(try store.storedBrief(sessionId: "s1", eventRowid: rowid)?.sessionId, "s1")
    }

    /// A second call writes nothing: one launch, one greeting, whatever retries
    /// happen above it.
    func testGreetingIsRecordedOnce() throws {
        XCTAssertNotNil(try LaunchGreeting.record(
            sessionId: "s1", directory: "/tmp/one", line: "a", store: store))
        XCTAssertNil(try LaunchGreeting.record(
            sessionId: "s1", directory: "/tmp/one", line: "a", store: store))
        XCTAssertEqual(try store.waitingSessions().count, 1)
    }

    /// Two agents started in the same directory are two agents.
    func testEachSessionGetsItsOwnGreeting() throws {
        _ = try LaunchGreeting.record(sessionId: "s1", directory: "/tmp/one",
                                      line: "a", store: store)
        _ = try LaunchGreeting.record(sessionId: "s2", directory: "/tmp/one",
                                      line: "b", store: store)
        XCTAssertEqual(Set(try store.waitingSessions().map(\.sessionId)), ["s1", "s2"])
    }

    // MARK: - The voice

    /// The greeting speaks before the session exists, so it has to be able to
    /// ask what voice that session is GOING to get — otherwise an agent
    /// introduces itself as one person and answers as another.
    func testTheGreetingIsSpokenInTheVoiceTheSessionKeeps() throws {
        let roster = ["alice", "bob", "carla"]
        let reserved = try XCTUnwrap(store.nextVoiceInRotation(roster: roster))
        _ = try LaunchGreeting.record(sessionId: "s1", directory: "/tmp/one",
                                      line: "a", voice: reserved, store: store)
        // What the session answers in, from then on, through the ordinary door.
        XCTAssertEqual(try store.voiceId(for: "s1", roster: roster), reserved)
    }

    /// The peek is the same arithmetic as the assignment, so the voice a launch
    /// speaks in is the one the rotation would have handed out anyway.
    func testThePeekMatchesTheRotation() throws {
        let roster = ["alice", "bob", "carla"]
        for i in 0..<5 {
            let peeked = try XCTUnwrap(store.nextVoiceInRotation(roster: roster))
            let assigned = try store.voiceId(for: "s\(i)", roster: roster)
            XCTAssertEqual(peeked, assigned, "assignment #\(i + 1)")
        }
    }

    /// First ask wins, reached from the other direction: a session that already
    /// has a voice keeps it, whatever a later greeting believes.
    func testAVoiceIsNeverReassigned() throws {
        let roster = ["alice", "bob"]
        let first = try XCTUnwrap(store.voiceId(for: "s1", roster: roster))
        XCTAssertEqual(try store.assignVoice("bob", to: "s1"), first)
        XCTAssertEqual(try store.voiceId(for: "s1", roster: roster), first)
    }

    /// No roster (no catalogue yet) is "the default voice", not a crash and not
    /// a bogus assignment.
    func testAnEmptyRosterReservesNothing() throws {
        XCTAssertNil(try store.nextVoiceInRotation(roster: []))
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
            timeout: 30, interval: 1, now: { clock }, sleep: { clock += $0 })
        XCTAssertNil(found)
        XCTAssertEqual(agents.calls, 30)
    }
}
