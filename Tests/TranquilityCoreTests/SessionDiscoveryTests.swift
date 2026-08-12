import XCTest
@testable import TranquilityCore

/// The classifier that decides which sessions exist, awake or not.
///
/// Two rules carry the whole feature and both fail quietly when wrong:
///
/// 1. `isAnswered` must not mistake a TOOL RESULT for you. Claude Code writes
///    tool results as `"type":"user"`, and in a 7-day window on this machine
///    241 of 499 transcripts end that way. A naive "is the last entry a user
///    entry" reads every one of them as answered, which retires sessions that
///    are mid-loop.
/// 2. `revivable` must never be true without positive evidence of absence.
///    `claude --resume` on a session that is still running adds a second live
///    entry under the SAME id, which crashed the app twice.
final class SessionDiscoveryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func assistant(_ text: String = "here is the thing") -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\(text)"}]}}
        """
    }
    private func prompt(_ text: String = "do the next bit") -> String {
        """
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"\(text)"}]}}
        """
    }
    private func toolResult() -> String {
        """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"}]}}
        """
    }

    // MARK: - isAnswered: the tool-result trap

    func testAgentSpokeLastIsUnanswered() {
        XCTAssertFalse(SessionDiscovery.isAnswered(tail: [prompt(), assistant()]))
    }

    func testYourPromptAfterTheAgentIsAnswered() {
        XCTAssertTrue(SessionDiscovery.isAnswered(tail: [assistant(), prompt()]))
    }

    /// The case that would silently break half the archive.
    func testToolResultIsNotAnAnswer() {
        XCTAssertFalse(SessionDiscovery.isAnswered(tail: [assistant(), toolResult()]))
    }

    func testStringContentPromptIsAnAnswer() {
        let line = #"{"type":"user","message":{"role":"user","content":"just words"}}"#
        XCTAssertTrue(SessionDiscovery.isAnswered(tail: [assistant(), line]))
    }

    /// Hook-injected entries are the harness talking to itself.
    func testMetaEntryIsNotAnAnswer() {
        let line = """
        {"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"<system-reminder>"}]}}
        """
        XCTAssertFalse(SessionDiscovery.isAnswered(tail: [assistant(), line]))
    }

    /// A subagent's traffic is written into the parent transcript.
    func testSidechainEntryIsNotAnAnswer() {
        let line = """
        {"type":"user","isSidechain":true,"message":{"role":"user","content":[{"type":"text","text":"go"}]}}
        """
        XCTAssertFalse(SessionDiscovery.isAnswered(tail: [assistant(), line]))
    }

    /// Every non-conversational type is skipped rather than enumerated, so a
    /// type added by a future Claude Code release cannot change the verdict.
    func testBookkeepingAfterTheAssistantIsSkipped() {
        let tail = [
            prompt(), assistant(),
            #"{"type":"last-prompt","leafUuid":"x"}"#,
            #"{"type":"attachment","attachment":{}}"#,
            #"{"type":"ai-title","aiTitle":"Something"}"#,
            #"{"type":"mode","mode":"normal"}"#,
            #"{"type":"invented-in-a-future-release","payload":1}"#,
        ]
        XCTAssertFalse(SessionDiscovery.isAnswered(tail: tail))
    }

    func testEmptyOrUnparseableTailOwesNothing() {
        XCTAssertTrue(SessionDiscovery.isAnswered(tail: []))
        XCTAssertTrue(SessionDiscovery.isAnswered(tail: ["not json at all", "{"]))
    }

    // MARK: - entrypoint: the filter that replaces the tty

    func testInteractiveIsExactlyCli() {
        XCTAssertTrue(SessionDiscovery.isInteractive("cli"))
        XCTAssertFalse(SessionDiscovery.isInteractive("sdk-cli"))
        XCTAssertFalse(SessionDiscovery.isInteractive(nil))
        XCTAssertFalse(SessionDiscovery.isInteractive(""))
    }

    /// A transcript can open with bookkeeping that carries no entrypoint.
    func testEntrypointIsFoundPastLeadingBookkeeping() {
        let head = [
            #"{"type":"queue-operation","operation":"enqueue"}"#,
            #"{"type":"last-prompt","leafUuid":"x"}"#,
            #"{"type":"user","entrypoint":"sdk-cli","cwd":"/tmp/robot"}"#,
        ]
        XCTAssertEqual(SessionDiscovery.entrypoint(head: head), "sdk-cli")
    }

    func testEntrypointAbsentIsNil() {
        XCTAssertNil(SessionDiscovery.entrypoint(head: [#"{"type":"user"}"#]))
    }

    // MARK: - cwd: read, never decoded

    /// The launch directory, not wherever the agent wandered to. A session that
    /// reads a skill's folder mid-run writes that folder as a later `cwd`, and
    /// resuming there would land in the wrong place.
    func testFirstCwdWinsOverLaterOnes() {
        let head = [
            #"{"type":"user","cwd":"/Users/x/Projects/kopi","entrypoint":"cli"}"#,
            #"{"type":"assistant","cwd":"/Users/x/Projects/kopi/.claude/skills/log-triage"}"#,
        ]
        XCTAssertEqual(SessionDiscovery.firstCwd(head: head), "/Users/x/Projects/kopi")
    }

    func testCwdAbsentIsNil() {
        XCTAssertNil(SessionDiscovery.firstCwd(head: [#"{"type":"queue-operation"}"#]))
    }

    // MARK: - The verb needs positive evidence of absence

    private func session(_ liveness: SessionDiscovery.Liveness,
                         revivable: Bool,
                         cwd: String? = "/Users/x/Projects/kopi") -> SessionDiscovery.Session {
        SessionDiscovery.Session(
            sessionId: "abc", cwd: cwd, transcriptPath: "/t.jsonl", title: nil,
            lastActivityAt: now, answered: false, activity: .idle,
            liveness: liveness, revivable: revivable)
    }

    func testGoneAndLandableOffersResume() {
        let command = session(.gone, revivable: true).reviveCommand
        XCTAssertEqual(command?.cwd, "/Users/x/Projects/kopi")
        XCTAssertEqual(command?.arguments, ["--resume", "abc"])
    }

    /// The crash case. An unproven session must never be offered the verb.
    func testUnknownLivenessOffersNothing() {
        XCTAssertNil(session(.unknown, revivable: false).reviveCommand)
    }

    func testLiveSessionOffersNothing() {
        XCTAssertNil(session(.live, revivable: false).reviveCommand)
    }

    /// A button that cannot work is worse than no button.
    func testMissingDirectoryOffersNothing() {
        XCTAssertNil(session(.gone, revivable: false).reviveCommand)
        XCTAssertNil(session(.gone, revivable: true, cwd: nil).reviveCommand)
    }

    // MARK: - The walk

    private final class StubAgents: ClaudeAgentsReading, @unchecked Sendable {
        let value: [LiveSession]?
        init(_ value: [LiveSession]?) { self.value = value }
        func sessions() -> [LiveSession]? { value }
    }

    private func makeArchive(_ files: [(slug: String, id: String, lines: [String])])
        throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("discover-\(UUID().uuidString)")
        for file in files {
            let dir = root.appendingPathComponent(file.slug)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try file.lines.joined(separator: "\n").write(
                to: dir.appendingPathComponent("\(file.id).jsonl"),
                atomically: true, encoding: .utf8)
        }
        return root
    }

    func testHeadlessSessionsAreCountedAndExcluded() throws {
        let root = try makeArchive([
            ("-tmp-a", "human", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
            ("-tmp-a", "robot", [#"{"type":"user","entrypoint":"sdk-cli","cwd":"/tmp"}"#, assistant()]),
            ("-tmp-a", "old", [#"{"type":"user","cwd":"/tmp"}"#, assistant()]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = SessionDiscovery.discover(
            live: StubAgents([]), projects: root, titles: TranscriptTitles())

        XCTAssertEqual(result.sessions.map(\.sessionId), ["human"])
        XCTAssertEqual(result.scanned, 3)
        XCTAssertEqual(result.headless, 1)
        XCTAssertEqual(result.unclassifiable, 1)
        XCTAssertFalse(result.livenessUnavailable)
    }

    /// "Could not determine" is not "none", and the difference decides whether
    /// a revive button appears.
    func testProbeFailureMakesEveryRowUnknownAndUnrevivable() throws {
        let root = try makeArchive([
            ("-tmp-a", "human", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = SessionDiscovery.discover(
            live: StubAgents(nil), projects: root, titles: TranscriptTitles())

        XCTAssertTrue(result.livenessUnavailable)
        XCTAssertEqual(result.sessions.first?.liveness, .unknown)
        XCTAssertFalse(result.sessions.first?.revivable ?? true)
        XCTAssertNil(result.sessions.first?.reviveCommand)
    }

    func testLiveSessionIsARowRatherThanAnAbsence() throws {
        let root = try makeArchive([
            ("-tmp-a", "awake", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let live = LiveSession(pid: 42, sessionId: "awake", cwd: "/tmp",
                               status: nil, name: nil, waitingFor: nil)
        let result = SessionDiscovery.discover(
            live: StubAgents([live]), projects: root, titles: TranscriptTitles())

        XCTAssertEqual(result.sessions.first?.liveness, .live)
        XCTAssertFalse(result.sessions.first?.revivable ?? true)
    }

    /// The whole point of the ruling: the process is gone and the row is not.
    func testClosedSessionSurvivesItsProcess() throws {
        let root = try makeArchive([
            ("-tmp-a", "closed", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = SessionDiscovery.discover(
            live: StubAgents([]), projects: root, titles: TranscriptTitles())

        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(session.liveness, .gone)
        XCTAssertEqual(session.cwd, "/tmp")
        XCTAssertTrue(session.revivable)
        XCTAssertFalse(session.answered)
        XCTAssertEqual(session.reviveCommand?.arguments, ["--resume", "closed"])
    }

    func testSessionsOutsideTheWindowAreNotScanned() throws {
        let root = try makeArchive([
            ("-tmp-a", "recent", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = SessionDiscovery.discover(
            window: 60, now: Date().addingTimeInterval(3600),
            live: StubAgents([]), projects: root, titles: TranscriptTitles())

        XCTAssertEqual(result.scanned, 0)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    /// A cap that drops rows in silence reads as "that is all of them".
    func testTheCapIsCounted() throws {
        let root = try makeArchive((0..<4).map { i in
            ("-tmp-a", "s\(i)", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()])
        })
        defer { try? FileManager.default.removeItem(at: root) }

        let result = SessionDiscovery.discover(
            limit: 2, live: StubAgents([]), projects: root, titles: TranscriptTitles())

        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.beyondLimit, 2)
    }

    /// A subagent is not an agent you can talk to, and there are three of them
    /// for every session on this machine.
    func testSubagentTranscriptsAreNotSessions() throws {
        let root = try makeArchive([
            ("-tmp-a", "parent", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
            ("-tmp-a/parent/subagents", "agent-abc",
             [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = SessionDiscovery.discover(
            live: StubAgents([]), projects: root, titles: TranscriptTitles())

        XCTAssertEqual(result.sessions.map(\.sessionId), ["parent"])
    }
}
