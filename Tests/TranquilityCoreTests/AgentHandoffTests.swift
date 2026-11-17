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

    // MARK: - The conversation itself (14 Nov)

    func testTheSameHarnessOnTheSameStoreForksAndEverythingElsePastes() {
        let claude = ClaudeCodeAdapter()
        XCTAssertEqual(
            AgentHandoff.carry(sourceBackend: "claude-code", destination: claude, sourceSessionId: "abc",
                               sourceConfigDirectory: nil, destinationConfigDirectory: nil),
            .nativeFork(arguments: ["--resume", "abc", "--fork-session"]))
        // Another harness cannot be handed this one's history.
        XCTAssertEqual(
            AgentHandoff.carry(sourceBackend: "codex", destination: claude, sourceSessionId: "abc",
                               sourceConfigDirectory: nil, destinationConfigDirectory: nil),
            .pastedLog)
        // A saved account reads another store: the session is not in it.
        XCTAssertEqual(
            AgentHandoff.carry(sourceBackend: "claude-code", destination: claude, sourceSessionId: "abc",
                               sourceConfigDirectory: nil, destinationConfigDirectory: "/Users/x/.claude-work"),
            .pastedLog)
        XCTAssertEqual(
            AgentHandoff.carry(sourceBackend: "claude-code", destination: claude, sourceSessionId: "abc",
                               sourceConfigDirectory: "/Users/x/.claude-work/",
                               destinationConfigDirectory: "/Users/x/.claude-work"),
            .nativeFork(arguments: ["--resume", "abc", "--fork-session"]))
        // Codex has a fork command nobody has run under this app yet.
        XCTAssertEqual(
            AgentHandoff.carry(sourceBackend: "codex", destination: CodexAdapter(), sourceSessionId: "abc",
                               sourceConfigDirectory: nil, destinationConfigDirectory: nil),
            .pastedLog)
    }

    func testAPastedLogRidesTheFragmentWithTheCommandsThatReachTheRest() {
        let log = "[41] user 2026-11-14 10:00:00\nRename the folders.\n\n[end of log: entry 41 of 41]"
        let fragment = AgentHandoff.fragment(
            sourceName: "Folder namer", sourceHarness: "codex", sourceSessionId: "s-1",
            logLocation: "/logs/s-1.jsonl", recentLog: log, reportsDirectory: nil)
        XCTAssertTrue(fragment.contains(log))
        XCTAssertTrue(fragment.contains("hq-log search s-1"))
        XCTAssertTrue(fragment.contains("hq-log outline s-1"))
        XCTAssertTrue(fragment.contains("hq-log show s-1"))
        XCTAssertFalse(fragment.contains("Read the recent end of the log"))
        // The log sits before the sentence that hands over to the user.
        let logAt = fragment.range(of: log)!.lowerBound
        let handAt = fragment.range(of: "user's current instruction")!.lowerBound
        XCTAssertLessThan(logAt, handAt)
    }

    func testAnOlderHandoffInsideThePastedLogDoesNotSwallowTheInstruction() {
        let older = AgentHandoff.fragment(
            sourceName: "First", sourceHarness: "codex", sourceSessionId: "s-0",
            logLocation: "/logs/s-0.jsonl", reportsDirectory: nil)
        let fragment = AgentHandoff.fragment(
            sourceName: "Second", sourceHarness: "codex", sourceSessionId: "s-1",
            logLocation: "/logs/s-1.jsonl",
            recentLog: "[1] user\n" + older + "\n\nan old instruction", reportsDirectory: nil)
        let sent = AttachmentTray.compose(transcript: "The new instruction.", fragments: [fragment])
        let read = AgentHandoff.continuation(in: sent)
        XCTAssertEqual(read?.sourceName, "Second")
        XCTAssertEqual(read?.sourceSessionId, "s-1")
        XCTAssertEqual(read?.instruction, "The new instruction.")
    }

    func testTheRecentLogIsTheCommandsOwnOutputAndAMissingFileIsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("s.jsonl")
        let rows = (1...40).map {
            "{\"type\":\"user\",\"timestamp\":\"2026-11-14T10:00:00Z\","
            + "\"message\":{\"content\":\"message number \($0) \(String(repeating: "x", count: 200))\"}}"
        }
        try rows.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        let command = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/bin/hq-log").path
        let tail = try XCTUnwrap(AgentHandoff.recentLog(logPath: log.path, tokens: 500, command: command))
        XCTAssertTrue(tail.contains("message number 40"))
        XCTAssertFalse(tail.contains("message number 1 "))
        XCTAssertTrue(tail.contains("are not shown here"))
        XCTAssertTrue(tail.hasSuffix("[end of log: entry 40 of 40]"))
        XCTAssertEqual(tail, AgentHandoff.recentLog(logPath: log.path, tokens: 500, command: command))
        XCTAssertNil(AgentHandoff.recentLog(logPath: dir.appendingPathComponent("no.jsonl").path, command: command))
    }
}
