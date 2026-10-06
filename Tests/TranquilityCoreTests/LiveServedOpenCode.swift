import XCTest
@testable import TranquilityCore

/// The served route end to end, on whichever OpenCode `TB_OPENCODE_BINARY`
/// names: the app's own `opencode serve`, a started agent, a question it asks
/// answered through the provider, the answer's turn said back, the session
/// listed, and a cancel. Run once per major version; gated, inert in CI.
///
///     TB_OPENCODE_BINARY=/path/to/opencode TB_TOY=/path/to/dir swift test --filter LiveServedOpenCode
final class LiveServedOpenCode: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipIf(env["TB_OPENCODE_BINARY"] == nil || env["TB_TOY"] == nil,
                      "set TB_OPENCODE_BINARY and TB_TOY")
    }

    func testStartAskAnswerHearAndCancel() async throws {
        let provider = ServedOpenCodeProvider(binary: env["TB_OPENCODE_BINARY"]!, directory: env["TB_TOY"]!,
                                              trace: { print("LIVE trace: \($0)") })
        defer { OpenCodeServer.stopAll() }

        actor Seen {
            var asked: PendingRequest?; var said: [String] = []; var completed = false
            func ask(_ r: PendingRequest) { asked = r }
            func say(_ t: String) { said.append(t) }
            func complete() { completed = true }
        }
        let seen = Seen()
        let id = try await provider.start(Brief(prompt: ""))
        let listen = Task {
            guard let stream = provider.changes() else { return }
            for await event in stream where event.session == id {
                switch event.kind {
                case .asks(let request): await seen.ask(request)
                case .said(let turn) where turn.role == .agent: await seen.say(turn.text)
                case .changed(let s) where s.state == .completed: await seen.complete()
                default: break
                }
            }
        }
        defer { listen.cancel() }

        let sent = try await provider.send(
            "Use your tool for asking the user a question to ask me whether I prefer red or blue, "
            + "as a multiple-choice question. Do not answer it yourself. After I answer, reply with "
            + "one sentence naming my choice.", to: id)
        XCTAssertEqual(sent, .accepted)

        let request = try await waitFor(90) { await seen.asked }
        print("LIVE asked: \(request.questions.map(\.asked)) options \(request.questions.first?.options.map(\.label) ?? [])")
        let blue = request.questions.first?.options.first { $0.label.lowercased().contains("blue") }
        let answered = try await provider.respond(to: request, with: Response(blue?.label ?? "Blue"))
        XCTAssertEqual(answered, .accepted)

        let said = try await waitFor(90) { () async -> String? in
            let all = await seen.said.joined(separator: " ")
            return all.lowercased().contains("blue") ? all : nil
        }
        print("LIVE said: \(said)")
        let transcript = try await provider.transcript(id)
        XCTAssertTrue(transcript.contains { $0.role == .user }, "the user's words are in the transcript")
        XCTAssertTrue(transcript.last?.text.lowercased().contains("blue") == true)

        let listed = try await provider.mine()
        XCTAssertTrue(listed.contains { $0.id == id }, "the started session is listed")
        let canceled = try await provider.cancel(id)
        XCTAssertEqual(canceled, .accepted)
    }

    private func waitFor<T>(_ seconds: TimeInterval, _ probe: () async -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = await probe() { return value }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTFail("timed out after \(Int(seconds)) s")
        throw CancellationError()
    }
}
