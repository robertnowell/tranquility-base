import XCTest
@testable import TranquilityCore

/// A LIVE probe against a real `opencode serve`, run by hand and never in CI.
///
/// Guarded on TB_LIVE_OPENCODE so it is inert everywhere else: CI has no
/// server, and a test that silently passes when its subject is absent is the
/// failure this whole branch keeps finding.
final class LiveOpenCodeProbe: XCTestCase {

    private var base: URL {
        URL(string: ProcessInfo.processInfo.environment["TB_LIVE_OPENCODE"] ?? "")!
    }

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TB_LIVE_OPENCODE"] == nil,
                      "set TB_LIVE_OPENCODE=http://127.0.0.1:4096")
    }

    private func provider() -> LocalOpenCodeProvider {
        LocalOpenCodeProvider(client: OpenCodeClient(
            transport: HTTPTransport(base: base, password: nil,
                                     trace: { print("LIVE trace: \($0)") }),
            provider: "opencode"))
    }

    /// The whole point: the REAL provider, the REAL transport, a REAL server.
    func testItConformsAgainstALiveServer() async throws {
        let p = provider()
        // A session has to exist for the suite to have anything to assert on.
        _ = try await p.start(Brief(prompt: ""))
        try await AgentProviderConformance.run(p, egress: false)
    }

    func testAStartedSessionAppearsAsARow() async throws {
        let p = provider()
        let id = try await p.start(Brief(prompt: ""))
        let mine = try await p.mine()
        XCTAssertTrue(mine.contains { $0.id == id }, "started a session and it did not appear")
        let session = mine.first { $0.id == id }!
        XCTAssertTrue(ArtifactStore.isPlausibleSession(session.id))
        XCTAssertFalse(session.providerID.isEmpty)
        XCTAssertEqual(session.provider, "opencode")
        print("LIVE row: id=\(session.id.prefix(12)) providerID=\(session.providerID) "
            + "title=\(session.title.isEmpty ? "<none>" : session.title)")
    }

    /// `changes()` non-nil is the push declaration, and the stream has to
    /// actually yield rather than merely exist.
    func testTheEventStreamConnectsAndYields() async throws {
        let p = provider()
        guard let stream = p.changes() else { return XCTFail("no stream from a live server") }
        // Raced against a clock, never bounded from inside the loop: a live
        // stream does not end, and a deadline checked only when an event
        // arrives never runs on a quiet one. Same defect this run found in the
        // conformance suite.
        let seen = await withTaskGroup(of: [String]?.self) { group -> [String] in
            group.addTask { @Sendable in
                var kinds: [String] = []
                for await event in stream {
                    kinds.append("\(event.kind)")
                    break
                }
                return kinds
            }
            group.addTask { @Sendable in
                // SUBSCRIBE FIRST, then provoke. `server.connected` carries no
                // session and is correctly filtered, so a client-level event
                // needs real traffic; starting a session before the
                // subscription attaches means the only event that would have
                // arrived already has.
                try? await Task.sleep(nanoseconds: 700_000_000)
                _ = try? await p.start(Brief(prompt: ""))
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
        for kind in seen { print("LIVE event: \(kind)") }
        XCTAssertGreaterThan(seen.count, 0, "the stream connected but yielded nothing in 10s")
    }

    /// The config path, which is how the app actually builds this provider.
    /// **The end-to-end run**, over the same HTTP path the app uses — not over
    /// ACP, which is a different client. Start a session, send it a real
    /// prompt, then READ THE ANSWER BACK, because `.accepted` is the server
    /// saying it took the request and not the agent having answered.
    ///
    /// This is the probe that was missing when OpenCode was called "validated":
    /// everything before it proved the agent could be LISTED and WATCHED, and
    /// nothing proved it could be driven.
    func testAPromptIsAnsweredAndTheAnswerComesBack() async throws {
        let provider = self.provider()
        let id = try await provider.start(Brief(prompt: ""))
        print("LIVE opencode session: \(id.prefix(16))")

        let stamp = "tb\(Int(Date().timeIntervalSince1970) % 100000)"
        let outcome = try await provider.send(
            "Reply with exactly this token and nothing else: \(stamp)", to: id)
        print("LIVE opencode send: \(outcome)")
        XCTAssertEqual(outcome, .accepted)

        var answered = false
        for attempt in 1...30 where !answered {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let turns = (try? await provider.transcript(id)) ?? []
            answered = turns.contains { $0.role == .agent && $0.text.contains(stamp) }
            if attempt % 5 == 0 || answered {
                print("LIVE opencode read-back \(attempt): \(turns.count) turn(s), "
                    + "answered: \(answered)")
            }
        }
        XCTAssertTrue(answered,
                      "the agent accepted a prompt and never answered it")
    }

    func testTheProviderBuildsFromTheMachinesOwnConfig() throws {
        let built = LocalOpenCodeProvider()
        XCTAssertNotNil(built, "hq.json has no providers.opencode.base_url")
        XCTAssertEqual(built?.id, "opencode")
    }

    /// `tbase check-keys` verifies against `/session`, not `/app`. Proving it
    /// here because `/app` returns HTML on a live server, which a status-only
    /// check reads as working: the same defect as the crobot route, and the
    /// reason that route moved.
    func testTheKeyCheckRouteIsAnApiRouteAndNotThePage() async throws {
        let request = KeyCheck.request(for: .openCodePassword, value: "probe",
                                       providerBase: { _ in self.base })
        XCTAssertEqual(request?.url?.path, "/session")
        let (data, response) = try await URLSession.shared.data(for: request!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("<!doctype"), "that is the web page, not an api route")
    }
}
