import XCTest
@testable import TranquilityCore

/// The harness writes down what we were inferring.
///
/// `~/.claude/sessions/<pid>.json` carries the session's own idle/busy status
/// and its tmux pane. Until 26 Aug this app inferred both — status off a
/// repainting screen, the pane off a `ps`-to-tty-to-inventory join — and both
/// inferences produced real, user-visible failures: a card holding a pid
/// twelve seconds dead, answering "couldn't find a terminal for process
/// 49931" about a pane one keystroke away.
///
/// The fixture is a real registry line, copied verbatim from this machine.
final class SessionRegistryTests: XCTestCase {

    private let real = #"""
    {"pid":32928,"sessionId":"2613715f-8627-4600-adbf-bd79190b29b1","cwd":"/private/tmp/tb-claude-verify","startedAt":1787760122876,"version":"2.1.246","peerProtocol":1,"kind":"interactive","entrypoint":"cli","tmux":"tb-2747d7fe:@69.%69","messagingSocketPath":"/tmp/cc-socks/32928.sock","name":"tb-claude-verify-86","status":"idle","updatedAt":1787760122787}
    """#

    func testItReadsWhatTheHarnessWroteDown() throws {
        let entry = try XCTUnwrap(SessionRegistry.decode(Data(real.utf8)))
        XCTAssertEqual(entry.pid, 32928)
        XCTAssertEqual(entry.sessionId, "2613715f-8627-4600-adbf-bd79190b29b1")
        XCTAssertEqual(entry.status, "idle")
        XCTAssertEqual(entry.cwd, "/private/tmp/tb-claude-verify")
        XCTAssertEqual(entry.messagingSocketPath, "/tmp/cc-socks/32928.sock")
    }

    /// The two halves of the address, split the way tmux wants them: commands
    /// address panes by `%id`, `attach` addresses sessions by name.
    func testThePaneAddressSplitsTheWayTmuxAsksForIt() throws {
        let entry = try XCTUnwrap(SessionRegistry.decode(Data(real.utf8)))
        XCTAssertEqual(entry.paneId, "%69")
        XCTAssertEqual(entry.tmuxSessionName, "tb-2747d7fe")
    }

    /// A session not under tmux records no pane, and must not be given one.
    func testASessionWithNoPaneOffersNone() throws {
        let json = #"{"pid":1,"sessionId":"abc","status":"busy"}"#
        let entry = try XCTUnwrap(SessionRegistry.decode(Data(json.utf8)))
        XCTAssertNil(entry.paneId)
        XCTAssertNil(entry.tmuxSessionName)
        XCTAssertEqual(entry.status, "busy")
    }

    /// A file being rewritten while we read it is ordinary, not an error, and
    /// must not take the whole sweep down with it.
    func testHalfWrittenFilesAreSkippedNotFatal() {
        XCTAssertNil(SessionRegistry.decode(Data(#"{"pid":32928,"sessi"#.utf8)))
        XCTAssertNil(SessionRegistry.decode(Data("".utf8)))
        XCTAssertNil(SessionRegistry.decode(Data(#"{"sessionId":"no-pid"}"#.utf8)))
        XCTAssertNil(SessionRegistry.decode(Data(#"{"pid":1,"sessionId":""}"#.utf8)),
                     "an empty session id would match every lookup")
    }

    /// The registry is keyed by pid, and a resumed session gets a new one —
    /// so two files can name one session and the newer one is the truth.
    func testTheNewestEntryWinsForASessionThatWasResumed() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let old = #"{"pid":100,"sessionId":"same","tmux":"tb-a:@1.%1","updatedAt":1000}"#
        let new = #"{"pid":200,"sessionId":"same","tmux":"tb-b:@2.%2","updatedAt":2000}"#
        try old.write(to: dir.appendingPathComponent("100.json"), atomically: true, encoding: .utf8)
        try new.write(to: dir.appendingPathComponent("200.json"), atomically: true, encoding: .utf8)

        let entry = try XCTUnwrap(SessionRegistry.entry(forSessionId: "same", in: dir))
        XCTAssertEqual(entry.pid, 200)
        XCTAssertEqual(entry.paneId, "%2", "the stale file names the pane the session has left")
    }

    /// Codex writes nothing here. Every lookup must return nil rather than
    /// guess, so the caller falls through to the path that still works.
    func testAnUnknownSessionIsNilRatherThanAGuess() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(SessionRegistry.entry(forSessionId: "codex-session", in: dir))
        XCTAssertTrue(SessionRegistry.all(in: dir).isEmpty)
    }

    /// And a directory that isn't there at all — a machine with no Claude
    /// Code sessions — is empty, never a crash.
    func testAMissingRegistryIsEmpty() {
        XCTAssertTrue(SessionRegistry.all(
            in: URL(fileURLWithPath: "/nonexistent/sessions")).isEmpty)
    }
}
