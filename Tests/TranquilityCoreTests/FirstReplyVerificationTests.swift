import XCTest
@testable import TranquilityCore

/// The first reply to a new agent, verified.
///
/// Claude Code creates `<sessionId>.jsonl` when the FIRST user message lands, so
/// on a session's first message the transcript cannot exist when the send starts.
/// The transport used to require the path up front and returned
/// `.verificationTimedOut` when it was missing — in about a second, without ever
/// entering the ten-second window. Measured on 18 Aug: session 8373bb2c's
/// transcript was born at 21:54:51 and the failure was logged at 21:54:51.
final class FirstReplyVerificationTests: XCTestCase {
    private var tmp: URL!
    private var projects: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("first-reply-\(UUID().uuidString)")
        projects = tmp.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projects.appendingPathComponent("-Users-x-Projects"),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, sessionId: String) throws {
        let line = #"{"type":"user","message":{"content":"\#(text)"}}"# + "\n"
        try Data(line.utf8).write(
            to: projects.appendingPathComponent("-Users-x-Projects/\(sessionId).jsonl"))
    }

    /// The load-bearing case: no transcript exists when the wait begins, and the
    /// file appears DURING it — which is exactly what happens, because the file
    /// is created by the message being watched for.
    func testATranscriptThatAppearsMidWaitConfirms() async throws {
        let sessionId = "new-session"
        // Only Sendable values cross into the task: an XCTestCase is not one,
        // and capturing `self` here is a data race the compiler is right about.
        let destination = projects.appendingPathComponent("-Users-x-Projects/\(sessionId).jsonl")
        let payload = Data((#"{"type":"user","message":{"content":"hello from the launch card"}}"# + "\n").utf8)
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            try? payload.write(to: destination)
        }
        let landed = await TranscriptWatcher.waitForUserText(
            "hello from the launch card", sessionId: sessionId, knownPath: nil,
            timeout: 5, pollInterval: 0.05, projects: projects)
        XCTAssertTrue(landed, "a file created during the wait must still confirm")
    }

    /// The regression this replaces: nothing ever arrives, so the wait must still
    /// end at its deadline rather than hanging or confirming a message that was
    /// never seen.
    func testATranscriptThatNeverAppearsStillTimesOut() async throws {
        let landed = await TranscriptWatcher.waitForUserText(
            "never typed", sessionId: "ghost", knownPath: nil,
            timeout: 0.4, pollInterval: 0.05, projects: projects)
        XCTAssertFalse(landed)
    }

    /// A caller that already holds a path keeps using it, and is not made to pay
    /// a directory scan per poll. The test harness depends on this: its
    /// transcripts do not live under `~/.claude/projects` at all.
    func testAKnownPathIsUsedWithoutScanning() async throws {
        let path = tmp.appendingPathComponent("elsewhere.jsonl")
        try Data((#"{"type":"user","message":{"content":"direct"}}"# + "\n").utf8)
            .write(to: path)
        let landed = await TranscriptWatcher.waitForUserText(
            "direct", sessionId: "unfindable", knownPath: path.path,
            timeout: 1, pollInterval: 0.05, projects: projects)
        XCTAssertTrue(landed)
    }

    /// A path that is known but not yet on disk is a normal state, not an error:
    /// the greeting row records the path the moment the session registers, which
    /// is before the file exists.
    func testAKnownPathThatDoesNotExistYetIsNotAFailure() async throws {
        let path = tmp.appendingPathComponent("later.jsonl")
        let payload = Data((#"{"type":"user","message":{"content":"eventually"}}"# + "\n").utf8)
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            try? payload.write(to: path)
        }
        let landed = await TranscriptWatcher.waitForUserText(
            "eventually", sessionId: "s", knownPath: path.path,
            timeout: 5, pollInterval: 0.05, projects: projects)
        XCTAssertTrue(landed)
    }
}
