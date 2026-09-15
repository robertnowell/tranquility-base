import XCTest
@testable import TranquilityCore

/// The registry, as the app builds it, spawns a real OpenCode over the protocol
/// and drives one turn, with nothing configured but the installed binary.
/// Gated on TB_LIVE_ACP_SPAWN=1 and TB_TOY; inert everywhere else.
final class LiveRegistrySpawn: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TB_LIVE_ACP_SPAWN"] == nil, "set TB_LIVE_ACP_SPAWN=1 TB_TOY=/path")
    }
    func testTheRegistryStartsAnInstalledAgentWithNoAddress() async throws {
        let toy = ProcessInfo.processInfo.environment["TB_TOY"]!
        // Point the workspace at the toy so the agent edits something harmless.
        let entry = ACPCatalog.published.first { $0.id == "opencode" }!
        guard let command = ACPCatalog.resolve(entry) else { return XCTFail("opencode not installed in any search path") }
        let transport = ACPProcessTransport(command: command, cwd: toy)
        let p = ACPProvider(id: "opencode", client: ACPClient(transport: transport), cwd: toy, start: { try transport.start() })
        let registry = AgentProviderRegistry([p], spawnable: ["opencode"])
        XCTAssertEqual(registry.configured(config: URL(fileURLWithPath: "/nonexistent.json")).map(\.id), ["opencode"])

        let before = try String(contentsOfFile: toy + "/greet.py", encoding: .utf8)
        actor Seen { var asked = 0; var said = 0; var finished = false; func a() { asked += 1 }; func s() { said += 1 }; func f() { finished = true } }
        let seen = Seen()
        guard let stream = p.changes() else { return XCTFail("no stream") }
        let reader = Task { for await ev in stream {
            switch ev.kind {
            case .asks(let req): await seen.a(); let pick = req.questions.first?.options.first?.id ?? ""; _ = try? await p.respond(to: req, with: Response(pick)); print("SPAWN: answered \(req.questions.first?.asked ?? "?") with \(pick)")
            case .said: await seen.s()
            case .changed(let s) where s.state.isFinished: await seen.f()
            default: break } } }
        let id = try await p.start(Brief(prompt: "In greet.py add a one-line docstring to greet() saying what it returns. Change nothing else. Reply DONE."))
        print("SPAWN: started \(id) via \(command[0])")
        let deadline = Date().addingTimeInterval(180)
        while await !seen.finished && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000_000) }
        reader.cancel()
        let after = try String(contentsOfFile: toy + "/greet.py", encoding: .utf8)
        let asked = await seen.asked, said = await seen.said, finished = await seen.finished
        print("SPAWN: asked=\(asked) said=\(said) finished=\(finished) changed=\(before != after)")
        print("SPAWN: greet.py now:\n\(after)")
        XCTAssertTrue(finished, "no terminal transition on the protocol stream")
        XCTAssertNotEqual(before, after, "the edit did not land")
    }
}
