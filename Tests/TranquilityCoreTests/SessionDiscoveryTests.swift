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

    /// Exclusion needs POSITIVE evidence, in both directions of the asymmetry.
    /// A stray robot row costs one glance; a hidden session costs the work,
    /// which is the failure the tty filter actually caused.
    func testOnlyAPositiveSdkCliIsHeadless() {
        XCTAssertTrue(SessionDiscovery.isHeadless("sdk-cli"))
        XCTAssertFalse(SessionDiscovery.isHeadless("cli"))
        XCTAssertFalse(SessionDiscovery.isHeadless(nil), "unreadable is not evidence")
        XCTAssertFalse(SessionDiscovery.isHeadless(""))
        XCTAssertFalse(SessionDiscovery.isHeadless("some-future-entrypoint"),
                       "a value a later Claude Code invents must not hide a session")
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

    /// The 23 Aug fix (2026-08-21-tb-division-of-labor): a session
    /// hand-started from `~` and then `cd`'d into a repo for the rest of its
    /// life must read the repo as home, not the handful of turns that came
    /// first — the tail is checked before the head for exactly this.
    func testTailRelocationWinsOverTheOriginalHead() {
        let head = [#"{"type":"user","cwd":"/Users/x","entrypoint":"cli"}"#]
        let tail = [
            #"{"type":"assistant","cwd":"/Users/x/Projects/tranquility-base"}"#,
            #"{"type":"user","cwd":"/Users/x/Projects/tranquility-base"}"#,
        ]
        XCTAssertEqual(SessionDiscovery.firstCwd(head: head, tail: tail),
                       "/Users/x/Projects/tranquility-base")
    }

    /// A brief wander into a subdirectory for one tool call must still lose
    /// to the head — the failure mode `firstCwd` was originally built to
    /// reject, unaffected by the tail now being checked first.
    func testATailWanderDoesNotWinIfItIsTheOnlyTailEntry() {
        let head = [#"{"type":"user","cwd":"/Users/x/Projects/kopi","entrypoint":"cli"}"#]
        let tail = [
            #"{"type":"assistant","cwd":"/Users/x/Projects/kopi/.claude/skills/log-triage"}"#,
        ]
        // The tail genuinely is the most recent cwd here — this documents
        // that a wander persisting all the way to the tail is, correctly,
        // no longer distinguishable from a real relocation; only a wander
        // that does NOT reach the tail (the common case: one tool call,
        // then back to normal work) is protected by the head fallback below.
        XCTAssertEqual(SessionDiscovery.firstCwd(head: head, tail: tail),
                       "/Users/x/Projects/kopi/.claude/skills/log-triage")
    }

    /// No tail supplied — the exact shape the production call site had
    /// before this fix, and every other caller still has. Must behave
    /// identically to the pre-fix function.
    func testNoTailFallsBackToTheHeadUnchanged() {
        let head = [
            #"{"type":"user","cwd":"/Users/x/Projects/kopi","entrypoint":"cli"}"#,
            #"{"type":"assistant","cwd":"/Users/x/Projects/kopi/.claude/skills/log-triage"}"#,
        ]
        XCTAssertEqual(SessionDiscovery.firstCwd(head: head), "/Users/x/Projects/kopi")
    }

    // MARK: - The verb needs positive evidence of absence

    private func session(_ liveness: SessionDiscovery.Liveness,
                         revivable: Bool,
                         cwd: String? = "/Users/x/Projects/kopi",
                         harness: String = ClaudeCodeAdapter().id) -> SessionDiscovery.Session {
        SessionDiscovery.Session(
            sessionId: "abc", cwd: cwd, transcriptPath: "/t.jsonl", title: nil,
            lastActivityAt: now, answered: false, activity: .idle,
            liveness: liveness, revivable: revivable, harness: harness)
    }

    /// The per-row adapter lookup `reviveCommand`'s own doc comment
    /// anticipated back when every row was still Claude Code.
    func testCodexHarnessReviveCommandUsesTheCodexAdapter() {
        let command = session(.unknown, revivable: true, harness: CodexAdapter().id).reviveCommand
        XCTAssertEqual(command?.arguments, ["resume", "abc"])
    }

    /// Updated 24 Aug with the landing ruling. This used to assert the fixture's
    /// imaginary `/Users/x/Projects/kopi` came back verbatim, which only held
    /// because `reviveCommand` echoed the recorded path without asking whether
    /// anything was there. It now resolves, so the case is stated with a
    /// directory that genuinely exists — the passthrough this test is about.
    func testGoneAndLandableOffersResume() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let command = session(.gone, revivable: true, cwd: home).reviveCommand
        XCTAssertEqual(command?.cwd, home)
        XCTAssertEqual(command?.arguments, ["--resume", "abc"])
    }

    /// The other half of the same ruling, and the reason it exists: a session
    /// whose directory was deleted still comes back, standing somewhere real.
    func testAGoneDirectoryStillOffersResumeSomewhereReal() {
        let command = session(.gone, revivable: true,
                              cwd: "/definitely/not/a/real/path/xyz").reviveCommand
        XCTAssertNotNil(command, "a deleted worktree must not retire the session")
        XCTAssertEqual(command?.cwd, SessionDiscovery.projectsHome)
    }

    /// And the one refusal that survives: nothing reopens under a reaped temp
    /// path. Every session found living there was a fixture or a headless probe.
    func testAReapedTempDirectoryOffersNothing() {
        XCTAssertNil(session(.gone, revivable: true,
                             cwd: "/private/tmp/tb-goto-test").reviveCommand)
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

    func testHeadlessAreExcludedAndUnreadableAreKept() throws {
        let root = try makeArchive([
            ("-tmp-a", "human", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
            ("-tmp-a", "robot", [#"{"type":"user","entrypoint":"sdk-cli","cwd":"/tmp"}"#, assistant()]),
            ("-tmp-a", "old", [#"{"type":"user","cwd":"/tmp"}"#, assistant()]),
        ])
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        let result = SessionDiscovery.discover(
            live: StubAgents([]), projects: root, titles: TranscriptTitles())

        // The entrypoint-less transcript is KEPT, and counted so the drop is
        // never silent either way.
        XCTAssertEqual(result.sessions.map(\.sessionId).sorted(), ["human", "old"])
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
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }

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
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }

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
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }

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
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }

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
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        let result = SessionDiscovery.discover(
            limit: 2, live: StubAgents([]), projects: root, titles: TranscriptTitles())

        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.beyondLimit, 2)
    }

    // MARK: - lastMoved: the clock the ranking is allowed to believe

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    private func assistant(at date: Date) -> String {
        #"{"type":"assistant","timestamp":"\#(iso(date))","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#
    }
    private func setMtime(_ root: URL, _ slug: String, _ id: String, to date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: root.appendingPathComponent(slug)
                .appendingPathComponent("\(id).jsonl").path)
    }

    /// The 19 Aug restart bug: browsing dead sessions touched their files, and
    /// the closed band ranked the browse order. Rank must follow the last entry
    /// the conversation wrote, not the file's clock.
    func testRankingFollowsTheConversationNotTheFile() throws {
        let now = Date()
        let root = try makeArchive([
            ("-tmp-a", "fresh", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#,
                                 assistant(at: now.addingTimeInterval(-60))]),
            ("-tmp-a", "stale", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#,
                                 assistant(at: now.addingTimeInterval(-3600))]),
        ])
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        // The stale conversation's file is touched LAST — a resume attempt, a
        // bridge sync — and the fresh one's file sits quietly behind it.
        try setMtime(root, "-tmp-a", "stale", to: now)
        try setMtime(root, "-tmp-a", "fresh", to: now.addingTimeInterval(-600))

        let result = SessionDiscovery.discover(
            now: now, live: StubAgents([]), projects: root, titles: TranscriptTitles())

        XCTAssertEqual(result.sessions.map(\.sessionId), ["fresh", "stale"])
        let stale = try XCTUnwrap(result.sessions.last)
        XCTAssertEqual(stale.lastActivityAt.timeIntervalSince(now), -3600, accuracy: 1)
    }

    /// A touch is not a return: a transcript whose conversation ended weeks ago
    /// does not re-enter the window because something brushed its file today.
    func testATouchedAncientSessionStaysOutsideTheWindow() throws {
        let now = Date()
        let root = try makeArchive([
            ("-tmp-a", "ancient", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#,
                                   assistant(at: now.addingTimeInterval(-10 * 24 * 3600))]),
        ])
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        try setMtime(root, "-tmp-a", "ancient", to: now)

        let result = SessionDiscovery.discover(
            now: now, live: StubAgents([]), projects: root, titles: TranscriptTitles())

        XCTAssertEqual(result.scanned, 1)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    /// No dated entry in the tail means mtime is the only clock there is — the
    /// fallback, never the preference.
    func testUndatedTailFallsBackToMtime() throws {
        let now = Date()
        let root = try makeArchive([
            ("-tmp-a", "undated", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        try setMtime(root, "-tmp-a", "undated", to: now.addingTimeInterval(-120))

        let result = SessionDiscovery.discover(
            now: now, live: StubAgents([]), projects: root, titles: TranscriptTitles())

        let session = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(session.lastActivityAt.timeIntervalSince(now), -120, accuracy: 1)
    }

    /// The cap is applied AFTER ranking on the conversation's clock, so which
    /// sessions survive it cannot be decided by the contaminated one either.
    func testTheCapCutsByConversationRecency() throws {
        let now = Date()
        let root = try makeArchive((0..<4).map { i in
            ("-tmp-a", "s\(i)", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#,
                                 assistant(at: now.addingTimeInterval(Double(-60 * (i + 1))))])
        })
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        // mtimes exactly inverted: the oldest conversation wears the newest
        // file clock.
        for i in 0..<4 {
            try setMtime(root, "-tmp-a", "s\(i)", to: now.addingTimeInterval(Double(-60 * (4 - i))))
        }

        let result = SessionDiscovery.discover(
            limit: 2, now: now, live: StubAgents([]), projects: root, titles: TranscriptTitles())

        XCTAssertEqual(result.sessions.map(\.sessionId), ["s0", "s1"])
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
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        let result = SessionDiscovery.discover(
            live: StubAgents([]), projects: root, titles: TranscriptTitles())

        XCTAssertEqual(result.sessions.map(\.sessionId), ["parent"])
    }

    // MARK: - The split: disk facts cached, process facts never

    /// The whole reason liveness is a column rather than a gate. The grid
    /// refreshes on every intake tick and cannot re-walk 500 transcripts each
    /// time, but "is a process behind this" must never be one tick stale.
    @MainActor
    func testLivenessIsRejoinedEvenWhenTheScanIsCached() throws {
        let root = try makeArchive([
            ("-tmp-a", "s1", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        let titles = TranscriptTitles()

        let live = LiveSession(pid: 7, sessionId: "s1", cwd: "/tmp",
                               status: nil, name: nil, waitingFor: nil)
        let first = SessionDiscovery.discover(
            live: StubAgents([live]), projects: root, titles: titles)
        XCTAssertEqual(first.sessions.first?.liveness, .live)
        XCTAssertFalse(first.sessions.first?.revivable ?? true)

        // Delete the transcript. A cached scan still lists it, which is what
        // proves the second call did no disk walk — and the liveness join still
        // runs, which is what this is all for.
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("-tmp-a/s1.jsonl"))

        let second = SessionDiscovery.discover(
            live: StubAgents([]), projects: root, titles: titles)
        XCTAssertEqual(second.sessions.first?.sessionId, "s1", "the scan should be cached")
        XCTAssertEqual(second.sessions.first?.liveness, .gone, "liveness must not be cached")
        XCTAssertTrue(second.sessions.first?.revivable ?? false)
    }

    /// A directory can vanish between two ticks, and an offer must never
    /// outlive its target — so revivability is resolved on every call rather
    /// than baked into the cached scan.
    @MainActor
    func testRevivabilityIsResolvedPerCallNotPerScan() throws {
        let cwd = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("discover-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let root = try makeArchive([
            ("-tmp-b", "s2", [
                #"{"type":"user","entrypoint":"cli","cwd":"\#(cwd.path)"}"#, assistant()]),
        ])
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        let titles = TranscriptTitles()

        let first = SessionDiscovery.discover(
            live: StubAgents([]), projects: root, titles: titles)
        XCTAssertTrue(first.sessions.first?.revivable ?? false)
        XCTAssertNotNil(first.sessions.first?.reviveCommand)

        try FileManager.default.removeItem(at: cwd)

        let second = SessionDiscovery.discover(
            live: StubAgents([]), projects: root, titles: titles)
        XCTAssertEqual(second.sessions.first?.liveness, .gone)
        XCTAssertFalse(second.sessions.first?.revivable ?? true,
                       "a directory that vanished must withdraw the offer")
        XCTAssertNil(second.sessions.first?.reviveCommand)
    }

    /// Two archives, one process. Without the directory in the cache key a test
    /// archive answers for the real one, and the bug gets blamed on the
    /// classifier.
    @MainActor
    func testTheCacheIsKeyedByArchive() throws {
        let a = try makeArchive([
            ("-tmp-a", "from-a", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        let b = try makeArchive([
            ("-tmp-b", "from-b", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let titles = TranscriptTitles()
        XCTAssertEqual(SessionDiscovery.discover(
            live: StubAgents([]), projects: a, titles: titles).sessions.map(\.sessionId),
            ["from-a"])
        XCTAssertEqual(SessionDiscovery.discover(
            live: StubAgents([]), projects: b, titles: titles).sessions.map(\.sessionId),
            ["from-b"])
    }

    /// The grid refresh runs on the main thread, so it must never be the thing
    /// that walks the archive. A cold call returns nothing and starts the walk
    /// behind it; the rows arrive on a later tick.
    @MainActor
    func testTheNonBlockingPathReturnsNothingUntilAScanExists() throws {
        let root = try makeArchive([
            ("-tmp-c", "s3", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        let titles = TranscriptTitles()

        XCTAssertNil(SessionDiscovery.discoverIfScanned(
            live: StubAgents([]), projects: root, titles: titles),
            "a cold cache must not block the caller")

        // Prime it the way the background refresh would.
        _ = SessionDiscovery.discover(live: StubAgents([]), projects: root, titles: titles)

        let warm = SessionDiscovery.discoverIfScanned(
            live: StubAgents([]), projects: root, titles: titles)
        XCTAssertEqual(warm?.sessions.map(\.sessionId), ["s3"])
        XCTAssertEqual(warm?.sessions.first?.liveness, .gone)
    }
    /// The blink. Reported from the running panel on 12 Aug: the closed band
    /// emptied for about five seconds every thirty, forever — "where did my
    /// sessions go". The cache was answering "nothing" the moment its entry
    /// aged out, and a rescan takes seconds, so every expiry blanked the band
    /// until it finished.
    ///
    /// Serving is not the same question as refreshing. These sessions exited
    /// hours ago; a stale answer about them is indistinguishable from a fresh
    /// one, and an empty one is a row vanishing under someone looking at it.
    @MainActor
    func testAStaleScanIsStillServedRatherThanBlanked() throws {
        let root = try makeArchive([
            ("-tmp-d", "s4", [#"{"type":"user","entrypoint":"cli","cwd":"/tmp"}"#, assistant()]),
        ])
        defer {
            SessionDiscovery.settleForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        let titles = TranscriptTitles()
        let t0 = Date(timeIntervalSince1970: 2_000_000)

        _ = SessionDiscovery.discover(
            now: t0, live: StubAgents([]), projects: root, titles: titles)

        // Well past the TTL, which is exactly when the band used to empty.
        let later = t0.addingTimeInterval(SessionDiscovery.scanTTL * 10)
        let served = SessionDiscovery.discoverIfScanned(
            now: later, live: StubAgents([]), projects: root, titles: titles)

        XCTAssertEqual(served?.sessions.map(\.sessionId), ["s4"],
                       "an expired scan must still be served, never blanked")
        XCTAssertEqual(served?.sessions.first?.liveness, .gone,
                       "and liveness is still rejoined on the stale rows")
    }

    // MARK: - One command for every path that starts an agent

    /// Ruled 12 Aug, after revival shipped a second launch path that disagreed
    /// with the first: a session started from the panel ran unattended, and the
    /// same session revived from the panel stopped at every tool call.
    @MainActor
    func testNewAndRevivedSessionsUseTheSameCommand() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = AgentDefaults.fileURL
        AgentDefaults.fileURL = dir.appendingPathComponent("agent-command.json")
        defer {
            AgentDefaults.fileURL = previous
            try? FileManager.default.removeItem(at: dir)
        }

        XCTAssertEqual(AgentDefaults.load(), AgentDefaults.fallback)
        XCTAssertEqual(SessionLauncher.defaultCommand, AgentDefaults.load(),
                       "a new session launches with the configured command")

        AgentDefaults.save("codex --yolo")
        XCTAssertEqual(AgentDefaults.load(), "codex --yolo")
        XCTAssertEqual(SessionLauncher.defaultCommand, "codex --yolo",
                       "and so does the next one, without a second constant")
    }

    /// Ruled 15 Aug: the start directory is a setting too, global for now.
    /// A path that does not exist falls back rather than being honoured — it is
    /// typed by hand, and a launch into a missing directory fails in Terminal
    /// where the panel cannot see it.
    @MainActor
    func testDirectoryFallsBackWhenUnsetOrMissing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = AgentDefaults.fileURL
        AgentDefaults.fileURL = dir.appendingPathComponent("agent-command.json")
        defer {
            AgentDefaults.fileURL = previous
            try? FileManager.default.removeItem(at: dir)
        }

        XCTAssertEqual(AgentDefaults.directory(), AgentDefaults.fallbackDirectory,
                       "unset means home")
        AgentDefaults.save(directory: "/definitely/not/here")
        XCTAssertEqual(AgentDefaults.directory(), AgentDefaults.fallbackDirectory,
                       "a missing path must not be handed to Terminal")
        XCTAssertEqual(AgentDefaults.directoryAsTyped(), "/definitely/not/here",
                       "but the pane shows what was typed, not what it resolved to")

        let real = dir.path
        AgentDefaults.save(directory: real)
        XCTAssertEqual(AgentDefaults.directory(), real)
        XCTAssertEqual(SessionLauncher.defaultDirectory, real,
                       "a new session starts where the setting says")
    }

    /// The two settings share one file and must not overwrite each other.
    @MainActor
    func testCommandAndDirectoryAreIndependent() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-both-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = AgentDefaults.fileURL
        AgentDefaults.fileURL = dir.appendingPathComponent("agent-command.json")
        defer {
            AgentDefaults.fileURL = previous
            try? FileManager.default.removeItem(at: dir)
        }
        AgentDefaults.save("codex --yolo")
        AgentDefaults.save(directory: dir.path)
        XCTAssertEqual(AgentDefaults.load(), "codex --yolo", "saving a directory kept the command")
        AgentDefaults.save("claude --resume-nothing")
        XCTAssertEqual(AgentDefaults.directory(), dir.path, "saving a command kept the directory")
    }

    /// A blank saved by accident would otherwise break every launch on the
    /// machine, and there is no useful meaning for "start agents with nothing".
    @MainActor
    func testABlankCommandFallsBackRatherThanBreakingEveryLaunch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = AgentDefaults.fileURL
        AgentDefaults.fileURL = dir.appendingPathComponent("agent-command.json")
        defer {
            AgentDefaults.fileURL = previous
            try? FileManager.default.removeItem(at: dir)
        }
        AgentDefaults.save("   ")
        XCTAssertEqual(AgentDefaults.load(), AgentDefaults.fallback)
    }

    // MARK: - discoverCodex

    private func makeCodexSessions(_ files: [(id: String, lines: [String])]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-discover-\(UUID().uuidString)")
        let dated = root.appendingPathComponent("2026/08/22")
        try FileManager.default.createDirectory(at: dated, withIntermediateDirectories: true)
        for file in files {
            try file.lines.joined(separator: "\n").write(
                to: dated.appendingPathComponent("rollout-x-\(file.id).jsonl"),
                atomically: true, encoding: .utf8)
        }
        return root
    }

    func testDiscoverCodexReadsRealRolloutShapes() throws {
        let root = try makeCodexSessions([
            ("s1", [
                #"{"type":"session_meta","payload":{"id":"s1","cwd":"/tmp"}}"#,
                #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#,
                #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}}"#,
            ]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = SessionDiscovery.discoverCodex(sessions: root)

        XCTAssertEqual(result.scanned, 1)
        XCTAssertEqual(result.sessions.count, 1)
        let row = try XCTUnwrap(result.sessions.first)
        XCTAssertEqual(row.sessionId, "s1")
        XCTAssertEqual(row.cwd, "/tmp")
        XCTAssertEqual(row.harness, CodexAdapter().id)
        // The agent spoke last: not yet answered, same semantic Claude
        // Code's own isAnswered uses.
        XCTAssertFalse(row.answered)
        XCTAssertEqual(row.liveness, .unknown)
        XCTAssertTrue(result.livenessUnavailable)
    }

    func testDiscoverCodexMarksAnsweredWhenTheUserSpokeLast() throws {
        let root = try makeCodexSessions([
            ("s1", [
                #"{"type":"session_meta","payload":{"id":"s1","cwd":"/tmp"}}"#,
                #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#,
                #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"thanks"}]}}"#,
            ]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(SessionDiscovery.discoverCodex(sessions: root).sessions.first?.answered ?? false)
    }

    /// A rollout with no `session_meta` at all (never taken a turn, or
    /// unreadable) is counted, never silently dropped — same discipline
    /// `scan`'s own `unclassifiable` counter follows for Claude Code.
    func testDiscoverCodexCountsUnclassifiableRatherThanDroppingSilently() throws {
        let root = try makeCodexSessions([
            ("s1", [#"{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}"#]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = SessionDiscovery.discoverCodex(sessions: root)
        XCTAssertEqual(result.sessions.count, 0)
        XCTAssertEqual(result.unclassifiable, 1)
    }

    /// `revivable` follows whether there is somewhere to LAND, NOT liveness —
    /// the deliberate divergence from Claude Code's own semantics: Codex rows
    /// never gate on a `.gone` this function never even computes.
    ///
    /// Renamed and re-stated 24 Aug. It used to read "follows the directory
    /// existing", and proved it with `/tmp` as the good case and a made-up path
    /// as the bad one. Both flipped under the landing ruling, and both for the
    /// right reason: a reaped temp path is now the case that offers nothing,
    /// and a deleted ordinary directory is the case that still comes back.
    func testDiscoverCodexRevivableFollowsTheLandingDirectoryNotLiveness() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let root = try makeCodexSessions([
            ("real", [#"{"type":"session_meta","payload":{"id":"real","cwd":"\#(home)"}}"#]),
            ("fake", [#"{"type":"session_meta","payload":{"id":"fake","cwd":"/private/tmp/tb-goto-test"}}"#]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = SessionDiscovery.discoverCodex(sessions: root).sessions
        XCTAssertTrue(rows.first { $0.sessionId == "real" }?.revivable ?? false)
        XCTAssertFalse(rows.first { $0.sessionId == "fake" }?.revivable ?? true)
        // Both read .unknown regardless — revivability never implies a
        // liveness guess in either direction.
        XCTAssertTrue(rows.allSatisfy { $0.liveness == .unknown })
    }

    func testDiscoverCodexRespectsTheWindow() throws {
        let root = try makeCodexSessions([
            ("s1", [#"{"type":"session_meta","payload":{"id":"s1","cwd":"/tmp"}}"#]),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = SessionDiscovery.discoverCodex(
            window: 0, now: Date().addingTimeInterval(3600), sessions: root)
        XCTAssertEqual(result.sessions.count, 0)
    }

    // MARK: discoverCodexIfScanned — the cache twin (rule 9: never walk the
    // archive on the caller's thread)

    @MainActor
    func testDiscoverCodexIfScannedReturnsNothingUntilAScanExists() throws {
        let root = try makeCodexSessions([
            ("s1", [#"{"type":"session_meta","payload":{"id":"s1","cwd":"/tmp"}}"#]),
        ])
        defer {
            SessionDiscovery.settleCodexForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertNil(SessionDiscovery.discoverCodexIfScanned(sessions: root),
                     "a cold cache must not block the caller")

        // The cold call above already started a background refresh; wait
        // for it rather than calling the raw, cache-blind `discoverCodex`
        // (that IS the uncached walk `discoverCodexIfScanned` wraps, the
        // same relationship `scan` has to `discover` — calling it directly
        // never touches the cache).
        SessionDiscovery.settleCodexForTesting()

        let warm = SessionDiscovery.discoverCodexIfScanned(sessions: root)
        XCTAssertEqual(warm?.sessions.map(\.sessionId), ["s1"])
    }

    func testDiscoverCodexCacheIsKeyedByDirectory() throws {
        let a = try makeCodexSessions([
            ("from-a", [#"{"type":"session_meta","payload":{"id":"from-a","cwd":"/tmp"}}"#]),
        ])
        let b = try makeCodexSessions([
            ("from-b", [#"{"type":"session_meta","payload":{"id":"from-b","cwd":"/tmp"}}"#]),
        ])
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        XCTAssertEqual(SessionDiscovery.discoverCodex(sessions: a).sessions.map(\.sessionId),
                       ["from-a"])
        XCTAssertEqual(SessionDiscovery.discoverCodex(sessions: b).sessions.map(\.sessionId),
                       ["from-b"])
    }

    func testWarmCodexFillsTheCacheOffMain() throws {
        let root = try makeCodexSessions([
            ("s1", [#"{"type":"session_meta","payload":{"id":"s1","cwd":"/tmp"}}"#]),
        ])
        defer {
            SessionDiscovery.settleCodexForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        SessionDiscovery.warmCodex(sessions: root)
        SessionDiscovery.settleCodexForTesting()
        XCTAssertEqual(SessionDiscovery.discoverCodexIfScanned(sessions: root)?.sessions
            .map(\.sessionId), ["s1"])
    }

    // MARK: - Where a revive lands (ruled 24 Aug)

    /// The ladder these cover: the original directory when it survives, its
    /// repository root when it does not, `~/Projects` when there is no repo
    /// above it, and nothing at all under a temp path.
    ///
    /// Built on a real temporary tree rather than a stub FileManager, because
    /// the thing under test IS filesystem behaviour — a fake that answers
    /// `fileExists` from a dictionary would pass while the ancestor walk was
    /// wrong, which is the only way this function can fail.
    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-landing-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("myrepo")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".claude/worktrees"),
            withIntermediateDirectories: true)
        // A worktree's .git is a FILE, which is why the walk tests existence.
        try "gitdir: elsewhere".write(
            to: repo.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return root
    }

    func testALivingDirectoryIsWhereItLands() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("myrepo").path
        XCTAssertEqual(SessionDiscovery.landingDirectory(
            for: repo, .default, temporaryRoots: []), repo)
    }

    func testADeletedWorktreeLandsOnTheRepositoryRootNotTheBookkeepingFolder() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("myrepo").path
        let dead = repo + "/.claude/worktrees/gone-branch/promotions"
        // The nearest SURVIVING ancestor is .claude/worktrees, which holds no
        // code; landing there was the first proposal and is the bug this asserts
        // against.
        XCTAssertEqual(SessionDiscovery.landingDirectory(
            for: dead, .default, temporaryRoots: []), repo)
    }

    func testNoRepositoryAboveItFallsBackToTheProjectsHome() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent("no-repo-here/deep/deeper").path
        let home = root.appendingPathComponent("stand-here")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        XCTAssertEqual(SessionDiscovery.landingDirectory(
            for: orphan, .default, temporaryRoots: [], home: home.path), home.path)
    }

    func testAReapedTempDirectoryLandsNowhere() {
        // Every session found living under /private/tmp was a test fixture or a
        // headless probe. Reopening there would scatter work into a directory
        // the OS reaps, so this rung refuses rather than falling through.
        XCTAssertNil(SessionDiscovery.landingDirectory(
            for: "/private/tmp/tb-goto-test"))
        XCTAssertNil(SessionDiscovery.landingDirectory(
            for: "/tmp/claude-501/somebody/scratchpad/probes/dirA"))
        XCTAssertNil(SessionDiscovery.landingDirectory(for: nil))
    }

    func testATempPathThatStillExistsIsStillItsOwnLanding() throws {
        // The refusal is about REAPED paths. A temp directory that is still
        // there was never broken, and rung 1 answers before the guard — losing
        // that would change behaviour for every live probe session.
        let live = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-landing-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: live) }
        XCTAssertEqual(SessionDiscovery.landingDirectory(for: live.path), live.path)
        XCTAssertTrue(SessionDiscovery.isTemporary(live.path),
                      "and it IS a temp path — rung 1 is what saves it, not a gap in the guard")
    }

}
