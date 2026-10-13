import XCTest
@testable import TranquilityCore

final class AgentHandoffTests: XCTestCase {
    private let roster: [AgentRoster.Agent] = [
        .init(id: "claude-code", name: "Claude Code", glyph: "✳", standing: .ready),
        .init(id: "codex", name: "Codex", glyph: "◆", standing: .needsSetup(.install("Install Codex"))),
        .init(id: "crobot", name: "crobot", glyph: "◇", standing: .ready),
        .init(id: "opencode", name: "OpenCode", glyph: "○", standing: .ready),
    ]

    func testEveryReadyAgentIsADestinationIncludingTheSourcesOwnKind() {
        let offered = AgentHandoff.destinations(ready: roster)
        XCTAssertEqual(offered.map(\.harness), ["claude-code", "crobot", "opencode"])
        XCTAssertEqual(offered.map(\.label), ["Claude Code", "crobot", "OpenCode"])
    }

    func testAnAgentThatCannotCarryTheFragmentIsNotOffered() {
        let offered = AgentHandoff.destinations(ready: roster, carriesFragment: { $0 != "crobot" })
        XCTAssertEqual(offered.map(\.harness), ["claude-code", "opencode"])
    }

    func testSourceLabelComesFromTheRoster() {
        XCTAssertEqual(AgentHandoff.sourceLabel(for: "opencode"), "OpenCode")
        XCTAssertEqual(AgentHandoff.sourceLabel(for: "codex"), "Codex")
        XCTAssertEqual(AgentHandoff.sourceLabel(for: "future-harness"), "future-harness")
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
        XCTAssertFalse(withoutReports.contains("The work lives in"))
        XCTAssertTrue(withoutReports.contains("user's current instruction"))

        let withReports = AgentHandoff.fragment(
            sourceName: "Search indexing",
            sourceHarness: ClaudeCodeAdapter().id,
            sourceSessionId: "session-123",
            directory: "/work/search",
            logLocation: "/logs/session-123.jsonl",
            reportsDirectory: "/reports/session-123")
        XCTAssertTrue(withReports.contains("(Claude Code, session session-123)"))
        XCTAssertTrue(withReports.contains("The work lives in:\n/work/search"))
        XCTAssertTrue(withReports.contains(
            "Recent reports are available under:\n/reports/session-123"))
    }
}
