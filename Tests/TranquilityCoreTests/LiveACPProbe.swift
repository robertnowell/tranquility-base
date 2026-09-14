import XCTest
@testable import TranquilityCore

/// The client against a REAL agent, spawned for the occasion.
///
/// Guarded on `TB_ACP_COMMAND` so it is inert in CI, which has no agent
/// installed. Every scripted test in `ACPClientTests` was written from what
/// this probe saw first: the fixtures are recordings, not inventions.
final class LiveACPProbe: XCTestCase {

    private var command: [String] {
        (ProcessInfo.processInfo.environment["TB_ACP_COMMAND"] ?? "")
            .split(separator: " ").map(String.init)
    }

    override func setUpWithError() throws {
        try XCTSkipIf(command.isEmpty, "set TB_ACP_COMMAND='/path/to/agent acp'")
    }

    func testAWholeTurnAgainstARealAgent() async throws {
        let cwd = ProcessInfo.processInfo.environment["TB_ACP_CWD"]
            ?? FileManager.default.currentDirectoryPath
        let transport = ACPProcessTransport(command: command, cwd: cwd)
        try transport.start()
        let client = ACPClient(transport: transport)
        await client.start()
        defer { Task { await client.close() } }

        // Collect what the agent says while the turn runs. Started BEFORE the
        // prompt, because a notification that arrives before anyone listens is
        // the bug this app keeps finding in itself.
        let heard = Watcher()
        let listening = Task {
            for await message in await client.inbound {
                await heard.record(message.method ?? "?")
            }
        }
        defer { listening.cancel() }

        let shook = try await client.initialize()
        print("LIVE ACP agent: \(shook.agentInfo?.name ?? "?") \(shook.agentInfo?.version ?? "")")
        print("LIVE ACP declares: loadSession=\(shook.agentCapabilities?.loadSession == true) "
            + "list=\(shook.agentCapabilities?.sessionCapabilities?.list == true) "
            + "resume=\(shook.agentCapabilities?.sessionCapabilities?.resume == true)")
        XCTAssertEqual(shook.protocolVersion, ACPWire.protocolVersion)

        let session = try await client.newSession(cwd: cwd)
        print("LIVE ACP session: \(session)")
        XCTAssertFalse(session.isEmpty)

        let result = try await client.prompt("Reply with exactly: ok", session: session)
        print("LIVE ACP stopReason: \(result.stopReason.map(\.rawValue) ?? "nil") "
            + "-> state \(result.state.rawValue)")
        XCTAssertEqual(result.state, .completed,
                       "a plain question should finish its turn, not fail or refuse")

        let methods = await heard.methods
        print("LIVE ACP heard: \(methods.sorted().joined(separator: ", "))")
        XCTAssertTrue(methods.contains("session/update"),
                      "a turn that produced no notification means nothing would reach the grid")
    }

    /// **The catch-up, against a real agent.** The conformance suite caught
    /// `mine()` returning nothing on a fixture; this proves the real
    /// `session/list` answers, that its stamps parse, and that a session which
    /// existed before this client attached is therefore reachable.
    func testSessionsFromBeforeWeAttachedAreFoundOnARealAgent() async throws {
        let cwd = ProcessInfo.processInfo.environment["TB_ACP_CWD"]
            ?? FileManager.default.currentDirectoryPath
        let transport = ACPProcessTransport(command: command, cwd: cwd)
        try transport.start()
        let client = ACPClient(transport: transport)
        let provider = ACPProvider(id: "opencode-acp", client: client, cwd: cwd)
        await provider.openEventStream()
        try await provider.connect()
        defer { Task { await client.close() } }

        let found = try await provider.mine()
        print("LIVE ACP mine(): \(found.count) session(s)")
        for session in found.prefix(4) {
            print("   \(session.providerID.prefix(14))  \(session.state.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))\(session.title.prefix(46))")
        }
        XCTAssertFalse(found.isEmpty,
                       "a push provider with no catch-up shows nothing after a gap")
        XCTAssertTrue(found.allSatisfy { $0.updatedAt > Date(timeIntervalSince1970: 1) },
                      "a stamp that failed to parse sorts the row to 1970")
        XCTAssertTrue(found.allSatisfy { $0.state != .unknown },
                      "unknown is not a first-class answer; it would paint these amber")
    }

    private actor Watcher {
        private(set) var methods: Set<String> = []
        func record(_ method: String) { methods.insert(method) }
    }
}

/// **Does the catalog tell the truth?**
///
/// Every published entry this machine actually has, driven through a real
/// handshake. A catalog is a list of CLAIMS about other people's software, and
/// the first time this ran, one of the three testable entries was wrong:
/// `cursor-agent` 2025.09.18 has no `acp` subcommand at all and drops into its
/// interactive TUI, so the client saw the pipe close.
///
/// Guarded on `TB_ACP_VERIFY` because it spawns real agents, and skipped
/// entirely in CI, which has none installed.
final class ACPCatalogVerification: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["TB_ACP_VERIFY"] == nil,
                      "set TB_ACP_VERIFY=1 to drive every installed agent")
    }

    func testEveryInstalledEntryActuallySpeaksACP() async throws {
        let installed = ACPCatalog.installed()
        print("VERIFY: \(installed.count) of \(ACPCatalog.published.count) published "
            + "agents are installed here")
        XCTAssertFalse(installed.isEmpty, "nothing to verify on this machine")

        var working: [String] = []
        var broken: [(String, String)] = []
        for (entry, command) in installed {
            let transport = ACPProcessTransport(command: command, cwd: NSTemporaryDirectory())
            let client = ACPClient(transport: transport)
            await client.setTimeout(.seconds(25))
            do {
                try transport.start()
                await client.start()
                let shook = try await client.initialize()
                working.append("\(entry.name) (\(shook.agentInfo?.name ?? "?") "
                    + "\(shook.agentInfo?.version ?? ""))")
            } catch {
                broken.append((entry.name, "\(error)"))
            }
            await client.close()
        }

        print("VERIFY working: \(working.joined(separator: ", "))")
        for (name, why) in broken { print("VERIFY BROKEN  \(name): \(why)") }

        // Deliberately NOT an assertion that everything works. A catalog entry
        // that is wrong on this machine may be right on the next one, and the
        // published list is a list, not a promise. What this asserts is that
        // SOMETHING works, so a wholesale regression in the client cannot hide
        // behind "well, none of them are installed".
        XCTAssertFalse(working.isEmpty,
                       "no installed agent completed a handshake: \(broken)")
    }
}
