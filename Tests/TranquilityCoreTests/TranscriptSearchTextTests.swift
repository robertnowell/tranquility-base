import XCTest
@testable import TranquilityCore

/// The two rules that make this text worth searching: injected context is not
/// what the session said, and the bound is on bytes.
final class TranscriptSearchTextTests: XCTestCase {

    private var dir: URL!
    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tst-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    private func write(_ lines: [String], _ name: String = "t.jsonl") -> String {
        let url = dir.appendingPathComponent(name)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testConversationIsSearchable() {
        let p = write([
            #"{"type":"user","message":{"content":"the microphone never opened"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Recording lost."}]}}"#,
        ])
        let text = TranscriptSearchText.shared.text(forTranscriptAt: p)
        XCTAssertTrue(text.contains("microphone"))
        XCTAssertTrue(text.contains("recording lost"), "lowercased for the filter")
    }

    /// The failure that made this a filter worth having: unfiltered, "klaviyo"
    /// matched all 60 sessions on this machine, because Claude Code writes the
    /// CLAUDE.md and the MCP instructions into every transcript.
    func testInjectedContextIsNotTheSession() {
        let p = write([
            #"{"type":"attachment","content":"CLAUDE.md mentions klaviyo everywhere"}"#,
            #"{"type":"system","content":"skill listing mentions klaviyo too"}"#,
            #"{"type":"user","isMeta":true,"message":{"content":"klaviyo in a meta record"}}"#,
            #"{"type":"user","message":{"content":"but this turn is about earcons"}}"#,
        ])
        let text = TranscriptSearchText.shared.text(forTranscriptAt: p)
        XCTAssertFalse(text.contains("klaviyo"), "injected context must not match")
        XCTAssertTrue(text.contains("earcons"))
    }

    /// Bounded on bytes: a transcript larger than the cap keeps its head and its
    /// tail — where the subject and the last thing it did live — and drops the
    /// middle, where a long session repeats itself.
    func testLargeTranscriptKeepsHeadAndTail() {
        let filler = String(repeating:
            #"{"type":"user","message":{"content":"filler filler filler"}}"# + "\n",
            count: 40_000)
        let p = write([
            #"{"type":"user","message":{"content":"opening subject spectrometer"}}"#,
            filler,
            #"{"type":"user","message":{"content":"closing subject kaleidoscope"}}"#,
        ])
        let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)??.intValue ?? 0
        XCTAssertGreaterThan(size, TranscriptSearchText.byteCap, "fixture must exceed the cap")
        let text = TranscriptSearchText.shared.text(forTranscriptAt: p)
        XCTAssertTrue(text.contains("spectrometer"), "head is kept")
        XCTAssertTrue(text.contains("kaleidoscope"), "tail is kept")
        // The cap plus the one newline joining the two halves — the seam the
        // reader documents. Anything larger would mean the middle leaked in.
        XCTAssertLessThanOrEqual(text.count, TranscriptSearchText.byteCap + 1)
        // And the middle really is dropped, not merely capped: the fixture holds
        // 40,000 filler records and the harvest must carry materially fewer.
        let kept = text.components(separatedBy: "filler filler filler").count - 1
        XCTAssertLessThan(kept, 40_000, "the middle leaked in")
        XCTAssertGreaterThan(kept, 0, "the fixture should still be mostly filler")
    }

    func testUnreadableFileIsEmptyNotACrash() {
        XCTAssertEqual(TranscriptSearchText.shared.text(
            forTranscriptAt: dir.appendingPathComponent("nope.jsonl").path), "")
    }
}
