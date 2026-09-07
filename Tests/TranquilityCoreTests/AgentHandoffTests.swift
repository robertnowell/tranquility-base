import XCTest
@testable import TranquilityCore

final class AgentHandoffTests: XCTestCase {
    func testDestinationIsAlwaysTheOtherKnownHarness() {
        XCTAssertEqual(
            AgentHandoff.destination(for: ClaudeCodeAdapter().id),
            .init(harness: CodexAdapter().id, label: "Codex"))
        XCTAssertEqual(
            AgentHandoff.destination(for: CodexAdapter().id),
            .init(harness: ClaudeCodeAdapter().id, label: "Claude Code"))
        XCTAssertNil(AgentHandoff.destination(for: nil))
        XCTAssertNil(AgentHandoff.destination(for: "future-harness"))
    }

    func testFragmentPointsAtLogsAndOnlyValidatedReports() {
        let withoutReports = AgentHandoff.fragment(
            sourceName: "Search indexing",
            sourceHarness: CodexAdapter().id,
            sourceSessionId: "session-123",
            logLocation: "/logs/session-123.jsonl",
            reportsDirectory: nil)
        XCTAssertTrue(withoutReports.hasPrefix(
            "Please continue the work of \u{201C}Search indexing\u{201D} (Codex, session session-123)."))
        XCTAssertTrue(withoutReports.contains("/logs/session-123.jsonl"))
        XCTAssertFalse(withoutReports.contains("Recent reports"))
        XCTAssertTrue(withoutReports.contains("user's current instruction"))

        let withReports = AgentHandoff.fragment(
            sourceName: "Search indexing",
            sourceHarness: ClaudeCodeAdapter().id,
            sourceSessionId: "session-123",
            logLocation: "/logs/session-123.jsonl",
            reportsDirectory: "/reports/session-123")
        XCTAssertTrue(withReports.contains("(Claude Code, session session-123)"))
        XCTAssertTrue(withReports.contains(
            "Recent reports are available under:\n/reports/session-123"))
    }
}
