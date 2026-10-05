import XCTest
@testable import TranquilityCore

final class CompletedTurnTextTests: XCTestCase {
    private func read(_ rows: [String], final: String = "Done", at: Double = 10) throws -> TurnText.Turn? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return TurnText.completed(in: url, finalMessage: final, completedAt: Date(timeIntervalSince1970: at))
    }

    private func row(_ role: String, _ text: String, _ seconds: Int, extra: String = "") -> String {
        let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return "{\"type\":\"\(role)\",\"timestamp\":\"1970-01-01T00:00:\(String(format: "%02d", seconds))Z\",\"message\":{\"content\":\(escaped)}\(extra)}"
    }

    func testCompleteTurnSurvivesLargeToolOutputAndHarnessPrompts() throws {
        let tool = "{\"type\":\"user\",\"toolUseResult\":{},\"message\":{\"content\":\"" + String(repeating: "x", count: 17 << 20) + "\"}}"
        let turn = try XCTUnwrap(read([
            row("user", "Old request", 0), row("assistant", "Old answer", 1),
            row("user", "Current request", 2), row("assistant", "Opening finding", 3), tool,
            row("user", "Task finished", 4, extra: ",\"origin\":{\"kind\":\"task-notification\"}"),
            row("assistant", "Middle finding", 5),
            row("user", "Skill text", 6, extra: ",\"isMeta\":true"), row("assistant", "Done", 7)]))
        XCTAssertEqual(turn.prompt, "Current request")
        XCTAssertEqual(turn.blocks, ["Opening finding", "Middle finding", "Done"])
    }

    func testDelayedSummaryDoesNotReadTheNextTurnEvenWithTheSameFinal() throws {
        let turn = try XCTUnwrap(read([
            row("user", "First request", 1), row("assistant", "First finding", 2), row("assistant", "Done", 3),
            row("user", "Second request", 11), row("assistant", "Second finding", 12), row("assistant", "Done", 13)]))
        XCTAssertEqual(turn.blocks, ["First finding", "Done"])
    }

    func testMissingBoundaryOrFinalIsNotCalledComplete() throws {
        XCTAssertNil(try read([row("assistant", "Orphan", 1), row("assistant", "Done", 2)]))
        XCTAssertNil(try read([row("user", "Request", 1), row("assistant", "Other final", 2)]))
        XCTAssertNil(try read([row("user", "Request", 1), "broken JSON", row("assistant", "Done", 2)]))
    }

    func testRolloutUsesContentOnceAndIgnoresScaffolding() throws {
        let rows = [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Request"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Finding"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"one","last_agent_message":"Done"}}"#]
        XCTAssertEqual(try read(rows)?.blocks, ["Finding", "Done"])
    }
}
