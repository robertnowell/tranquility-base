import XCTest
@testable import TranquilityCore

/// The delivery watermark: history is not evidence about this delivery.
/// Regression net for the 19 Aug audit finding — a short reply ("yes") that
/// ever appeared in an earlier user message false-confirmed without sending,
/// because dedupe and landing checks matched by substring over the whole
/// transcript.
final class TranscriptWatermarkTests: XCTestCase {

    private func write(_ lines: [String]) throws -> String {
        let dir = NSTemporaryDirectory() + "watermark-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/t.jsonl"
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true,
                                                         encoding: .utf8)
        return path
    }

    private func userLine(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }

    func testHistoryBeforeWatermarkIsInvisible() throws {
        let path = try write([userLine("yes"), userLine("go ahead")])
        let watermark = TranscriptWatcher.fileSize(atPath: path)

        // The exact false-confirm shape: "yes" exists in history, and the
        // watermarked read must NOT see it.
        XCTAssertTrue(TranscriptWatcher.userMessages(in: path).contains { $0.contains("yes") })
        XCTAssertFalse(TranscriptWatcher.userMessages(in: path, fromByteOffset: watermark)
            .contains { $0.contains("yes") })

        // A genuinely new append IS seen from the same watermark.
        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data((userLine("yes") + "\n").utf8))
        try handle.close()
        XCTAssertTrue(TranscriptWatcher.userMessages(in: path, fromByteOffset: watermark)
            .contains { $0.contains("yes") })
    }

    func testMissingFileHasZeroWatermarkAndNoMessages() {
        XCTAssertEqual(TranscriptWatcher.fileSize(atPath: "/nonexistent/nowhere.jsonl"), 0)
        XCTAssertEqual(TranscriptWatcher.fileSize(atPath: nil), 0)
        XCTAssertTrue(TranscriptWatcher.userMessages(in: "/nonexistent/nowhere.jsonl",
                                                     fromByteOffset: 0).isEmpty)
    }

    func testZeroWatermarkReadsEverything() throws {
        let path = try write([userLine("first"), userLine("second")])
        let all = TranscriptWatcher.userMessages(in: path, fromByteOffset: 0)
        XCTAssertEqual(all, ["first", "second"])
    }

    func testWatermarkBisectingARecordSkipsOnlyTheFragment() throws {
        let path = try write([userLine("older message")])
        // A watermark taken mid-append lands inside the record being written.
        // The fragment fails JSON parse and is skipped — and the record it
        // belonged to began before the watermark, so excluding it is the
        // point, not a loss.
        let midRecord = TranscriptWatcher.fileSize(atPath: path) - 10
        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data((userLine("newer message") + "\n").utf8))
        try handle.close()

        let seen = TranscriptWatcher.userMessages(in: path, fromByteOffset: midRecord)
        XCTAssertEqual(seen, ["newer message"])
    }

    func testWaitForUserTextHonorsWatermark() async throws {
        let path = try write([userLine("merge it")])
        let watermark = TranscriptWatcher.fileSize(atPath: path)
        // Present in history only: must time out, not false-confirm.
        let confirmedFromHistory = await TranscriptWatcher.waitForUserText(
            "merge it", in: path, timeout: 0.3, pollInterval: 0.05,
            fromByteOffset: watermark)
        XCTAssertFalse(confirmedFromHistory)

        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data((userLine("merge it") + "\n").utf8))
        try handle.close()
        let confirmedFromAppend = await TranscriptWatcher.waitForUserText(
            "merge it", in: path, timeout: 1, pollInterval: 0.05,
            fromByteOffset: watermark)
        XCTAssertTrue(confirmedFromAppend)
    }

    // MARK: codexUserMessages / waitForCodexUserText — the same watermark
    // discipline, over Codex's own rollout schema. A real bug, found live
    // 22 Aug: reading a Codex rollout through the Claude Code parser above
    // finds zero messages, always — every line is `session_meta`/
    // `event_msg`/`response_item`, never `{"type":"user",…}` — which broke
    // both verification (a real send timed out despite landing and getting
    // a reply) and dedup (the same broken read let a retry inject the
    // payload a second time into a live session).

    private func codexUserLine(_ text: String) -> String {
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(text)"}]}}"#
    }

    func testCodexHistoryBeforeWatermarkIsInvisible() throws {
        let path = try write([codexUserLine("yes"), codexUserLine("go ahead")])
        let watermark = TranscriptWatcher.fileSize(atPath: path)

        XCTAssertTrue(TranscriptWatcher.codexUserMessages(in: path, fromByteOffset: 0)
            .contains { $0.contains("yes") })
        XCTAssertFalse(TranscriptWatcher.codexUserMessages(in: path, fromByteOffset: watermark)
            .contains { $0.contains("yes") })

        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data((codexUserLine("yes") + "\n").utf8))
        try handle.close()
        XCTAssertTrue(TranscriptWatcher.codexUserMessages(in: path, fromByteOffset: watermark)
            .contains { $0.contains("yes") })
    }

    func testCodexUserMessagesNeverMatchesTheClaudeCodeParser() throws {
        // The exact shape of the bug: a Claude Code line never appears as a
        // Codex message, and vice versa — pinned directly so a future
        // "simplify by sharing one parser" change cannot silently
        // reintroduce this.
        let claudeStylePath = try write([userLine("hello")])
        XCTAssertTrue(TranscriptWatcher.codexUserMessages(
            in: claudeStylePath, fromByteOffset: 0).isEmpty)

        let codexStylePath = try write([codexUserLine("hello")])
        XCTAssertTrue(TranscriptWatcher.userMessages(
            in: codexStylePath, fromByteOffset: 0).isEmpty)
    }

    func testCodexUserMessagesIgnoresNonUserRecords() throws {
        let path = try write([
            #"{"type":"session_meta","payload":{"id":"s1","cwd":"/tmp"}}"#,
            codexUserLine("real message"),
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"a reply"}]}}"#,
        ])
        XCTAssertEqual(TranscriptWatcher.codexUserMessages(in: path, fromByteOffset: 0),
                       ["real message"])
    }

    func testMissingCodexFileHasNoMessages() {
        XCTAssertTrue(TranscriptWatcher.codexUserMessages(
            in: "/nonexistent/nowhere.jsonl", fromByteOffset: 0).isEmpty)
    }

    func testWaitForCodexUserTextHonorsWatermark() async throws {
        let path = try write([codexUserLine("merge it")])
        let watermark = TranscriptWatcher.fileSize(atPath: path)
        let confirmedFromHistory = await TranscriptWatcher.waitForCodexUserText(
            "merge it", path: path, timeout: 0.3, pollInterval: 0.05,
            fromByteOffset: watermark)
        XCTAssertFalse(confirmedFromHistory)

        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data((codexUserLine("merge it") + "\n").utf8))
        try handle.close()
        let confirmedFromAppend = await TranscriptWatcher.waitForCodexUserText(
            "merge it", path: path, timeout: 1, pollInterval: 0.05,
            fromByteOffset: watermark)
        XCTAssertTrue(confirmedFromAppend)
    }
}
