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
    /// **The end-to-end run.** Send a real message to a real task on the live
    /// gateway, then READ IT BACK, because `.accepted` is the gateway saying it
    /// took the request and not the message existing.
    ///
    /// Guarded on its own variable, separate from `TB_LIVE_CROBOT`, because
    /// every other probe here is read-only and this one writes to somebody's
    /// actual task. Reading and writing are different permissions and the
    /// environment should have to say so twice.
    func testAMessageActuallyReachesALiveTask() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TB_CROBOT_SEND"] == nil,
                      "set TB_CROBOT_SEND=1 — this WRITES to a live task")

        let mine = try await provider.mine()
        guard let target = mine.first(where: { $0.state != .working }) else {
            throw XCTSkip("no idle task to write to; every one is mid-turn")
        }
        print("LIVE crobot send -> \(target.providerID)  \(target.title.prefix(46))")

        // A sentence that is obviously a connectivity check and obviously not
        // an instruction, stamped so it can be found among real messages.
        let stamp = "tb-probe-\(Int(Date().timeIntervalSince1970))"
        let text = "Tranquility Base connectivity check \(stamp). No action needed."

        let outcome = try await provider.send(text, to: target.id)
        print("LIVE crobot send outcome: \(outcome)")
        XCTAssertEqual(outcome, .accepted, "the gateway refused the message")

        // And now the part that actually proves it: find it in the transcript.
        var found = false
        for attempt in 1...20 where !found {
            try await Task.sleep(nanoseconds: 4_000_000_000)
            let turns = (try? await provider.transcript(target.id)) ?? []
            found = turns.contains { $0.text.contains(stamp) }
            print("LIVE crobot read-back \(attempt): \(turns.count) turn(s), "
                + "mine present: \(found)")
        }
        XCTAssertTrue(found,
                      "the gateway accepted a message that never appeared in the task")
    }

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
