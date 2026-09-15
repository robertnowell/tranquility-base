import XCTest
@testable import TranquilityCore

/// Subscribe FIRST, then prompt, and count what the provider's stream delivers.
/// The raw server emitted 33 SSE lines during a five-second turn; the drive
/// probe saw zero through `changes()`. This isolates which side is wrong.
final class LiveOpenCodeStream: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    override func setUpWithError() throws {
        try XCTSkipIf(env["TB_LIVE_OPENCODE"] == nil, "set TB_LIVE_OPENCODE")
    }
    func testSubscribeThenPromptDeliversEvents() async throws {
        let p = LocalOpenCodeProvider(client: OpenCodeClient(
            transport: HTTPTransport(base: URL(string: env["TB_LIVE_OPENCODE"]!)!, password: nil,
                                     trace: { print("LIVE trace: \($0)") }),
            provider: "opencode"))
        actor Count { var kinds: [String] = []; func add(_ k: String) { kinds.append(k) } }
        let count = Count()
        guard let stream = p.changes() else { return XCTFail("changes() returned nil") }
        let reader = Task { for await ev in stream { await count.add("\(ev.kind)".prefix(24).description) } }
        try await Task.sleep(nanoseconds: 1_500_000_000)          // let the subscription open
        let id = try await p.start(Brief(prompt: ""))
        let out = try await p.send("Reply with the single word PONG and do nothing else.", to: id)
        print("LIVE stream: send -> \(out)")
        try await Task.sleep(nanoseconds: 15_000_000_000)
        reader.cancel()
        let kinds = await count.kinds
        print("LIVE stream: delivered \(kinds.count) events: \(Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count))")
        XCTAssertGreaterThan(kinds.count, 0, "provider stream delivered nothing while the server emitted")
    }
}
