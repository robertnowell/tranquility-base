import XCTest
@testable import TranquilityCore

/// A LIVE probe against the real gateway, run by hand and inert everywhere
/// else. Guarded on TB_LIVE_CROBOT so CI, which has no key, skips it: a test
/// that silently passes when its subject is absent is the failure this whole
/// branch keeps finding.
final class LiveCrobotProbe: XCTestCase {

    private var key: String { ProcessInfo.processInfo.environment["TB_LIVE_CROBOT"] ?? "" }

    override func setUpWithError() throws {
        try XCTSkipIf(key.isEmpty, "set TB_LIVE_CROBOT to a jrv_ key")
    }

    private var provider: CrobotProvider {
        CrobotProvider(
            transport: CrobotHTTPTransport(
                base: URL(string: "https://crobot.coframe.com")!, key: key),
            me: nil)
    }

    /// The whole point: the real transport, the real gateway, the real filter.
    func testItListsThisUsersLiveTasksAndNobodyElses() async throws {
        let mine = try await provider.mine()
        print("LIVE crobot: \(mine.count) row(s)")
        for session in mine.prefix(5) {
            print("  \(session.state.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0))"
                + "\(session.repository ?? "-")  \(session.title.prefix(48))")
        }
        // 115 tasks are visible on the gateway and 7 are this user's, of which
        // one was live when this was written. The assertion is deliberately
        // about the SHAPE rather than the number, which moves.
        XCTAssertLessThan(mine.count, 20,
                          "the createdBy and archived filters are not running")
        for session in mine {
            XCTAssertEqual(session.provider, "crobot")
            XCTAssertTrue(ArtifactStore.isPlausibleSession(session.id))
        }
    }

    /// The identity the filter depends on. Without it `mine()` shows nothing,
    /// which is the safe direction but not a working one.
    func testTheGatewayNamesTheKeysOwner() async throws {
        let who = try await CrobotHTTPTransport(
            base: URL(string: "https://crobot.coframe.com")!, key: key).identity()
        print("LIVE crobot identity: \(who ?? "<none>")")
        XCTAssertNotNil(who)
        XCTAssertTrue(who?.contains("@") == true)
    }
}
