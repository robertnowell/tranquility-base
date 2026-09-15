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

extension LiveCrobotProbe {

    /// **Against the live gateway: crobot asks the real repo question, then a
    /// chosen repo actually creates a task.** This is the path that only ever
    /// errored from the app.
    func testStartAsksForARealRepoAndThenCreates() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TB_CROBOT_SEND"] == nil,
                      "set TB_CROBOT_SEND=1 — this CREATES a live task")
        let p = provider

        let questions = try await p.startQuestions(for: Brief(prompt: "warm-up"))
        let repos = questions.first?.options.map(\.id) ?? []
        print("LIVE crobot repo question: \(questions.first?.asked ?? "none")")
        print("LIVE crobot repos: \(repos.joined(separator: ", "))")
        XCTAssertFalse(repos.isEmpty, "the live gateway returned no repos to choose from")

        // Choose the repo the org itself defaults to, so the created task lands
        // where a person's own New task page would put it.
        guard let repo = repos.first(where: { $0.hasSuffix("/crobot") }) ?? repos.first else {
            throw XCTSkip("no repo offered")
        }
        var brief = Brief(prompt: "Tranquility Base connectivity check "
            + "\(Int(Date().timeIntervalSince1970)). No action needed; you may stop.")
        brief.repository = repo
        let id = try await p.start(brief)
        print("LIVE crobot created task: \(id.prefix(12)) in \(repo)")
        XCTAssertFalse(id.isEmpty, "start returned no task id")

        // And it is real: it shows up as one of my tasks.
        var found = false
        for _ in 1...8 where !found {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            found = (try? await p.mine())?.contains { $0.id == id } ?? false
        }
        print("LIVE crobot new task visible in mine(): \(found)")
        XCTAssertTrue(found, "the created task never appeared in this key's task list")
    }
}
