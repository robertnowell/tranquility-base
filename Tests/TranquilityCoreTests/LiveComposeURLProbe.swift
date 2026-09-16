import XCTest
@testable import TranquilityCore

/// What New Agent → crobot will REALLY open, from this machine's own config.
final class LiveComposeURLProbe: XCTestCase {
    func testTheRealURLNewAgentWouldOpen() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TB_LIVE_GRID"] == nil,
                      "set TB_LIVE_GRID=1")
        let reg = AgentProviders.registry()
        guard let crobot = reg.configured().first(where: { $0.id == "crobot" }) else {
            throw XCTSkip("crobot not configured here")
        }
        var brief = Brief(prompt: "")
        print("LIVE composeURL (no repo): \(crobot.composeURL(for: brief)?.absoluteString ?? "nil")")
        brief.repository = "Coframe/crobot"
        print("LIVE composeURL (repo):    \(crobot.composeURL(for: brief)?.absoluteString ?? "nil")")
        XCTAssertEqual(crobot.composeURL(for: Brief(prompt: ""))?.host, "crobot.coframe.com")
    }
}
