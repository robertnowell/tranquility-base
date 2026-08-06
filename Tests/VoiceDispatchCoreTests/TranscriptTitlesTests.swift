import Foundation
import Testing
@testable import VoiceDispatchCore

/// The tab-string scanner: last ai-title wins, appends are picked up
/// incrementally, partial trailing lines are never split, truncation resets.
struct TranscriptTitlesTests {

    private func tempTranscript(_ lines: [String]) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-titles-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("session.jsonl").path
        FileManager.default.createFile(
            atPath: path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))
        return path
    }

    private func append(_ path: String, _ text: String) {
        let handle = FileHandle(forWritingAtPath: path)!
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    @Test func lastTitleWins() {
        let path = tempTranscript([
            #"{"type":"user","message":"hello"}"#,
            #"{"type":"ai-title","aiTitle":"first title","sessionId":"s"}"#,
            #"{"type":"assistant","message":"ai-title mentioned in prose"}"#,
            #"{"type":"ai-title","aiTitle":"second title","sessionId":"s"}"#,
        ])
        #expect(TranscriptTitles().latestTitle(transcriptPath: path) == "second title")
    }

    @Test func noTitleYetIsNil() {
        let path = tempTranscript([#"{"type":"user","message":"hello"}"#])
        #expect(TranscriptTitles().latestTitle(transcriptPath: path) == nil)
    }

    @Test func missingFileIsNil() {
        #expect(TranscriptTitles().latestTitle(transcriptPath: "/nonexistent/x.jsonl") == nil)
    }

    @Test func appendsArePickedUpIncrementally() {
        let path = tempTranscript([#"{"type":"ai-title","aiTitle":"old","sessionId":"s"}"#])
        let titles = TranscriptTitles()
        #expect(titles.latestTitle(transcriptPath: path) == "old")
        append(path, #"{"type":"ai-title","aiTitle":"new","sessionId":"s"}"# + "\n")
        #expect(titles.latestTitle(transcriptPath: path) == "new")
    }

    @Test func partialTrailingLineIsReReadOnceComplete() {
        let path = tempTranscript([#"{"type":"ai-title","aiTitle":"old","sessionId":"s"}"#])
        let titles = TranscriptTitles()
        #expect(titles.latestTitle(transcriptPath: path) == "old")
        // A record mid-flush: no newline yet, so the cursor must not eat it.
        append(path, #"{"type":"ai-title","aiTitle":"ne"#)
        #expect(titles.latestTitle(transcriptPath: path) == "old")
        append(path, #"w","sessionId":"s"}"# + "\n")
        #expect(titles.latestTitle(transcriptPath: path) == "new")
    }

    @Test func truncationResetsTheCursor() {
        let path = tempTranscript([#"{"type":"ai-title","aiTitle":"long-lived title","sessionId":"s"}"#])
        let titles = TranscriptTitles()
        #expect(titles.latestTitle(transcriptPath: path) == "long-lived title")
        try! Data((#"{"type":"ai-title","aiTitle":"reborn","sessionId":"s"}"# + "\n").utf8)
            .write(to: URL(fileURLWithPath: path))
        #expect(titles.latestTitle(transcriptPath: path) == "reborn")
    }

    @Test func defaultPathSlugsNonAlphanumerics() {
        let path = TranscriptTitles.defaultPath(cwd: "/Users/x/a.b", sessionId: "abc-123")
        #expect(path.hasSuffix("/.claude/projects/-Users-x-a-b/abc-123.jsonl"))
    }
}
