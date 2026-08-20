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
}
