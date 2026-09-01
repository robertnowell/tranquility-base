import XCTest
@testable import TranquilityCore

/// Fixtures here are synthetic, matching the codebase's own convention
/// (`TranscriptTitlesTests`) — but every shape they cover was found by
/// reading real rollouts on this machine first: 192 files, six Codex
/// versions from 0.133.0-alpha.1 to 0.149.0 (21 Aug). That sweep is why
/// `session_id`-absent is a fixture and not a hypothetical (the field
/// doesn't exist before ~0.144), why `<environment_context>` filtering
/// exists at all (found in a real rollout from a live probe the same day),
/// and why `compacted`/`world_state`/`inter_agent_communication_metadata`
/// appear as "must not crash" cases rather than an invented list.
final class CodexRolloutTests: XCTestCase {

    // MARK: session_meta

    func testSessionMetaReadsIdWhenSessionIdIsAbsent() {
        // Every 0.133.0-alpha.1-era rollout on this machine looks like this.
        let text = #"""
        {"type":"session_meta","payload":{"id":"019ea2b8-56cc-7002-aa66-533d2f878796","cwd":"/Users/robert","cli_version":"0.133.0-alpha.1"}}
        """#
        let parsed = CodexRollout.parse(text)
        XCTAssertEqual(parsed.meta?.sessionId, "019ea2b8-56cc-7002-aa66-533d2f878796")
        XCTAssertEqual(parsed.meta?.cwd, "/Users/robert")
        XCTAssertEqual(parsed.meta?.cliVersion, "0.133.0-alpha.1")
    }

    func testSessionMetaReadsIdEvenWhenSessionIdDiffers() {
        // Distinct values on purpose (gate finding, 21 Aug): the prior
        // fixture used the SAME string for both fields, so an
        // implementation reading `session_id` — the exact bug this pins
        // against — would have passed identically.
        let text = #"""
        {"type":"session_meta","payload":{"session_id":"wrong-field","id":"right-field","cwd":"/tmp","cli_version":"0.149.0"}}
        """#
        XCTAssertEqual(CodexRollout.parse(text).meta?.sessionId, "right-field")
    }

    func testOnlyTheFirstSessionMetaCounts() {
        // A forked/sub-agent rollout can carry a second session_meta for the
        // child thread (observed, forked_from_id/parent_thread_id present).
        // The file's own identity is the first record, not the last.
        let text = #"""
        {"type":"session_meta","payload":{"id":"parent-thread","cwd":"/a"}}
        {"type":"session_meta","payload":{"id":"child-thread","cwd":"/b","forked_from_id":"parent-thread"}}
        """#
        XCTAssertEqual(CodexRollout.parse(text).meta?.sessionId, "parent-thread")
    }

    func testMissingSessionMetaIsNilNotACrash() {
        let parsed = CodexRollout.parse(#"{"type":"turn_context","payload":{}}"#)
        XCTAssertNil(parsed.meta)
    }

    // MARK: busy / idle and last_agent_message

    func testUnmatchedTaskStartedReadsAsBusy() {
        let text = #"""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        """#
        XCTAssertTrue(CodexRollout.parse(text).isBusy)
    }

    func testMatchedTaskCompletePairReadsAsIdle() {
        let text = #"""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"ADAPTER-PROBE-OK"}}
        """#
        let parsed = CodexRollout.parse(text)
        XCTAssertFalse(parsed.isBusy)
        XCTAssertEqual(parsed.completions, [.init(turnId: "t1", lastAgentMessage: "ADAPTER-PROBE-OK")])
    }

    func testTwoTurnsOneStillOpenReadsAsBusy() {
        // The dual-message probe this adapter's own capabilities were
        // measured against: a second turn queued and started while the
        // first was still finishing.
        let text = #"""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"ADAPTER-PROBE-OK"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}
        """#
        let parsed = CodexRollout.parse(text)
        XCTAssertTrue(parsed.isBusy)
        XCTAssertEqual(parsed.completions.count, 1)
    }

    func testTurnAbortedClearsBusyState() {
        // The user hit Esc. Gate finding, 21 Aug: unhandled, this alone
        // made 55/192 real rollouts on this machine (29%) read as falsely
        // busy — 13 purely from this, no task_complete ever coming.
        let text = #"""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}
        {"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","reason":"interrupted"}}
        """#
        let parsed = CodexRollout.parse(text)
        XCTAssertFalse(parsed.isBusy)
        // `completions` means "turns that ENDED", each saying how, since
        // 01 Sep. It used to mean "turns that produced a last_agent_message",
        // which left an abort visible only as the absence of busy — nothing a
        // caller could read a reason out of, and the lamp logic went and
        // hand-rolled its own rollout walk partly for want of it. An abort is
        // still not a completion, and now it can say so in its own words.
        XCTAssertEqual(parsed.completions.count, 1)
        XCTAssertEqual(parsed.completions.first?.aborted, true)
        XCTAssertNil(parsed.completions.first?.lastAgentMessage,
                     "no last_agent_message exists on an abort")
        XCTAssertEqual(parsed.completions.first?.failed, false,
                       "the person who pressed Esc does not need telling")
    }

    func testTaskCompleteWithNoMatchingTaskStartedIsNotFatal() {
        // A rollout read starting mid-turn (or a `task_started` this parse
        // never saw for any other reason) — Set.remove on an absent
        // element is a documented no-op. The turn IS complete; isBusy must
        // still read false, and the completion is still recorded.
        let text = #"""
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"orphaned","last_agent_message":"done"}}
        """#
        let parsed = CodexRollout.parse(text)
        XCTAssertFalse(parsed.isBusy)
        XCTAssertEqual(parsed.completions, [.init(turnId: "orphaned", lastAgentMessage: "done")])
    }

    func testExternalImportTurnIdsAreOpaqueStringsNotUUIDs() {
        // A real 0.133.0-alpha.1 rollout on this machine uses turn ids like
        // "external-import-turn-1" — never assume UUID shape.
        let text = #"""
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"external-import-turn-1"}}
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"external-import-turn-1","last_agent_message":"ok"}}
        """#
        XCTAssertEqual(CodexRollout.parse(text).completions.first?.turnId, "external-import-turn-1")
    }

    // MARK: messages — the environment_context filter

    func testFirstUserMessageWrappingEnvironmentContextIsFiltered() {
        let text = #"""
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/tmp</cwd>\n</environment_context>"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"reply with exactly ADAPTER-PROBE-OK and nothing else"}]}}
        """#
        let messages = CodexRollout.parse(text).messages
        XCTAssertEqual(messages.count, 1, "the environment_context wrapper is not conversation content")
        XCTAssertEqual(messages.first?.text, "reply with exactly ADAPTER-PROBE-OK and nothing else")
        XCTAssertEqual(messages.first?.role, "user")
    }

    func testEnvironmentContextIsFilteredAtAnyPosition() {
        // Gate finding, 21 Aug: measured across 192 real rollouts, the
        // wrapper is not a first-of-turn heuristic — one real file carries
        // it only at message #22, several carry it more than once. A
        // position-based filter would have missed those; this one doesn't
        // check position at all, and this pins that down.
        let text = #"""
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"first real message"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"first reply"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/tmp</cwd>\n</environment_context>"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"second real message"}]}}
        """#
        let messages = CodexRollout.parse(text).messages
        XCTAssertEqual(messages.map(\.text), ["first real message", "first reply", "second real message"])
    }

    func testTextThatOnlyStartsLikeTheWrapperIsNotFiltered() {
        // The over-breadth case the gate specifically asked about: someone
        // pasting a snippet of rollout debugging output that happens to
        // START with the wrapper's opening tag, but is not actually the
        // wrapper (no matching close). Without the closing-tag check this
        // is a real, if rare, false positive — a human's real message
        // silently dropped.
        let text = #"""
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context> is the XML wrapper Codex injects, right? I was reading the rollout format docs."}]}}
        """#
        XCTAssertEqual(CodexRollout.parse(text).messages.count, 1,
                       "starts with the tag but never closes it — real content, must not be filtered")
    }

    func testDeveloperRoleMessagesAreExcluded() {
        // Sampled across 614 real occurrences on this machine: every one is
        // injected system context (output-style instructions, permission
        // profile XML, multi-agent preambles), the same category
        // environment_context exists to strip — never anything a human or
        // TB typed (gate finding, 21 Aug — keeping these while filtering
        // environment_context was an inconsistency, not a decision).
        let text = #"""
        {"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"You are in 'learning' output style mode..."}]}}
        """#
        XCTAssertEqual(CodexRollout.parse(text).messages, [])
    }

    func testAgentMessageRoutingRecordsAreExcluded() {
        // A real response_item payload type (142 occurrences on this
        // machine), but its own author/recipient fields and "Message Type:
        // FINAL_ANSWER" framing show it is Codex's own inter-agent routing
        // protocol, not a conversational turn — deliberately excluded.
        let text = #"""
        {"type":"response_item","payload":{"type":"agent_message","author":"/root/sub","recipient":"/root","content":[{"type":"input_text","text":"Message Type: FINAL_ANSWER"}]}}
        """#
        XCTAssertEqual(CodexRollout.parse(text).messages, [])
    }

    func testAssistantMessagesAreKept() {
        let text = #"""
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ADAPTER-PROBE-OK"}]}}
        """#
        XCTAssertEqual(CodexRollout.parse(text).messages,
                       [.init(role: "assistant", text: "ADAPTER-PROBE-OK")])
    }

    func testReasoningItemsCarryNoPlainTextAndAreSkipped() {
        // Real shape: `encrypted_content`, no `content` array at all.
        let text = #"""
        {"type":"response_item","payload":{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"gAAAA..."}}
        """#
        XCTAssertEqual(CodexRollout.parse(text).messages, [])
    }

    // MARK: unrecognized record types — must not crash, must not pollute

    func testUnrecognizedRecordTypesAreSkippedCleanly() {
        // All four appear on real rollouts on this machine; none carries
        // anything this type models.
        let text = #"""
        {"type":"world_state","payload":{"full":true,"state":{}}}
        {"type":"turn_context","payload":{"turn_id":"t1","cwd":"/tmp"}}
        {"type":"compacted","payload":{}}
        {"type":"inter_agent_communication_metadata","payload":{}}
        {"type":"session_meta","payload":{"id":"s1","cwd":"/tmp"}}
        """#
        let parsed = CodexRollout.parse(text)
        XCTAssertEqual(parsed.meta?.sessionId, "s1")
        XCTAssertEqual(parsed.skippedLines, 0, "recognized-and-ignored is not the same as undecodable")
        XCTAssertEqual(parsed.messages, [])
        XCTAssertEqual(parsed.completions, [])
        XCTAssertFalse(parsed.isBusy)
    }

    func testMalformedLineIsSkippedNotFatal() {
        let text = "not json at all\n" + #"{"type":"session_meta","payload":{"id":"s1"}}"#
        let parsed = CodexRollout.parse(text)
        XCTAssertEqual(parsed.meta?.sessionId, "s1")
        XCTAssertEqual(parsed.skippedLines, 1, "undecodable, not recognized-and-ignored — must be visible")
    }

    func testEmptyTextParsesToNothing() {
        let parsed = CodexRollout.parse("")
        XCTAssertNil(parsed.meta)
        XCTAssertEqual(parsed.messages, [])
        XCTAssertFalse(parsed.isBusy)
    }

    // MARK: filesystem — rolloutPath(forSessionId:)

    private func tempSessionsDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-sessions-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: dir.appendingPathComponent("2026/08/21"), withIntermediateDirectories: true)
        return dir
    }

    func testRolloutPathFindsByFilenameSuffixNotContent() {
        // FOUND from the filename Codex itself writes, the same discipline
        // TranscriptArchive uses for Claude Code — never a guessed layout.
        let sessions = tempSessionsDir()
        let target = sessions.appendingPathComponent(
            "2026/08/21/rollout-2026-08-21T20-27-15-01a02782-25fd-7342-b383-eb0fa5323b92.jsonl")
        try! Data().write(to: target)
        let found = CodexRollout.rolloutPath(
            forSessionId: "01a02782-25fd-7342-b383-eb0fa5323b92", sessions: sessions)
        // Compared by resolved path, not literal equality: /tmp is a
        // symlink to /private/tmp on macOS, and FileManager's enumerator
        // returns the resolved form while the URL built by hand above does
        // not — a test-harness quirk, not a fact about `rolloutPath` itself.
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       target.resolvingSymlinksInPath().path)
    }

    func testRolloutPathIsNilWhenNoFileMatches() {
        let sessions = tempSessionsDir()
        XCTAssertNil(CodexRollout.rolloutPath(forSessionId: "nothing-here", sessions: sessions))
    }

    func testRolloutPathDoesNotMatchAPrefixOfAnotherId() {
        // "abc" must not match a file actually named "...-xabc.jsonl" — a
        // real hazard for suffix matching, absent from Claude Code's
        // exact-filename lookup because that one has no timestamp prefix.
        let sessions = tempSessionsDir()
        let decoy = sessions.appendingPathComponent("2026/08/21/rollout-2026-08-21T20-00-00-xabc.jsonl")
        try! Data().write(to: decoy)
        XCTAssertNil(CodexRollout.rolloutPath(forSessionId: "abc", sessions: sessions))
    }

    func testParseSessionIdReadsAndParsesInOneCall() {
        let sessions = tempSessionsDir()
        let target = sessions.appendingPathComponent(
            "2026/08/21/rollout-2026-08-21T20-27-15-real-id.jsonl")
        try! Data(#"{"type":"session_meta","payload":{"id":"real-id","cwd":"/tmp"}}"#.utf8)
            .write(to: target)
        let parsed = CodexRollout.parse(sessionId: "real-id", sessions: sessions)
        XCTAssertEqual(parsed?.meta?.cwd, "/tmp")
    }

    func testParseSessionIdIsNilWhenTheFileDoesNotExistYet() {
        // A thread that has never taken a turn — real and tolerated, the
        // same state TranscriptArchive.transcriptPath returns nil for.
        let sessions = tempSessionsDir()
        XCTAssertNil(CodexRollout.parse(sessionId: "never-written", sessions: sessions))
    }

    // MARK: - liveThreadIds (App-lane, default launcher, 26 Aug)
    //
    // Found live: a brand-new, message-less `codex` launch writes a
    // <threadId>.lock here immediately — before any rollout exists, which
    // is exactly the case testParseSessionIdIsNilWhenTheFileDoesNotExistYet
    // above already knew was real. This is the seam that actually answers
    // "has a new thread started" for that case.

    private func tempLocksDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-locks-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testLiveThreadIdsReadsEveryLockStrippedOfItsExtension() throws {
        let locks = tempLocksDir()
        let a = UUID().uuidString, b = UUID().uuidString
        try Data().write(to: locks.appendingPathComponent("\(a).lock"))
        try Data().write(to: locks.appendingPathComponent("\(b).lock"))
        XCTAssertEqual(Set(CodexRollout.liveThreadIds(locks: locks)), [a, b])
    }

    /// Only `.lock` files count — a stray file of another kind in the same
    /// directory must not read as a thread id.
    func testLiveThreadIdsIgnoresNonLockFiles() throws {
        let locks = tempLocksDir()
        let a = UUID().uuidString
        try Data().write(to: locks.appendingPathComponent("\(a).lock"))
        try Data("not a lock".utf8).write(to: locks.appendingPathComponent("README.txt"))
        XCTAssertEqual(CodexRollout.liveThreadIds(locks: locks), [a])
    }

    /// Found live sharing this exact directory: `.coordination.lock`, a
    /// stable file with no thread behind it at all — a `.lock` suffix
    /// alone is not enough, the base name has to be a real thread id.
    func testLiveThreadIdsIgnoresNonUUIDLockFiles() throws {
        let locks = tempLocksDir()
        let a = UUID().uuidString
        try Data().write(to: locks.appendingPathComponent("\(a).lock"))
        try Data().write(to: locks.appendingPathComponent(".coordination.lock"))
        XCTAssertEqual(CodexRollout.liveThreadIds(locks: locks), [a])
    }

    func testLiveThreadIdsIsEmptyForAMissingDirectory() {
        let locks = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-locks-never-created-\(UUID().uuidString)")
        XCTAssertEqual(CodexRollout.liveThreadIds(locks: locks), [])
    }

    /// Newest first — the ordering `awaitCodexRegistration` relies on when
    /// more than one lock is new in the same poll.
    func testLiveThreadIdsOrdersNewestFirst() throws {
        let locks = tempLocksDir()
        let olderId = UUID().uuidString, newerId = UUID().uuidString
        let older = locks.appendingPathComponent("\(olderId).lock")
        try Data().write(to: older)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: older.path)
        let newer = locks.appendingPathComponent("\(newerId).lock")
        try Data().write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: newer.path)
        XCTAssertEqual(CodexRollout.liveThreadIds(locks: locks), [newerId, olderId])
    }
}
