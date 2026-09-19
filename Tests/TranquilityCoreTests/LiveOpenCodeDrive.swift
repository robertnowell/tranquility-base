import XCTest
@testable import TranquilityCore

/// Drive a local OpenCode agent END TO END through the provider seam: start a
/// session on a toy project, let it do a harmless edit, answer anything it
/// asks, wait for it to finish, read the transcript back, and prove the work
/// landed on disk. Gated on TB_LIVE_OPENCODE and TB_TOY; inert everywhere else.
final class LiveOpenCodeDrive: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipIf(env["TB_LIVE_OPENCODE"] == nil || env["TB_TOY"] == nil,
                      "set TB_LIVE_OPENCODE=http://127.0.0.1:4097 TB_TOY=/path/to/toy")
    }

    private func provider() -> LocalOpenCodeProvider {
        LocalOpenCodeProvider(client: OpenCodeClient(
            transport: HTTPTransport(base: URL(string: env["TB_LIVE_OPENCODE"]!)!, password: nil,
                                     trace: { print("LIVE trace: \($0)") }),
            provider: "opencode"))
    }

    func testDriveAToyEditEndToEnd() async throws {
        let p = provider()
        let toy = env["TB_TOY"]!
        let before = try String(contentsOfFile: toy + "/greet.py", encoding: .utf8)
        XCTAssertFalse(before.contains("\"\"\""), "toy must start without a docstring")

        let prompt = "In greet.py, add a one-line docstring to the greet() function saying what it returns. Change nothing else. Do not create, delete or rename any files. When done, reply with the single word DONE."
        let id = try await p.start(Brief(prompt: prompt))
        print("LIVE drive: started \(id)")

        actor Tally {
            var answered = 0, events = 0, finished = false; var failure: String?
            func event() { events += 1 }
            func answer() { answered += 1 }
            func finish() { finished = true }
            func fail(_ r: String) { failure = r }
            func answer_() -> Int { answered }
            func events_() -> Int { events }
        }
        let tally = Tally()
        let deadline = Date().addingTimeInterval(240)
        let streamTask: Task<Void, Never>? = p.changes().map { stream in
            Task {
                for await ev in stream {
                    await tally.event()
                    switch ev.kind {
                    case .asks(let req) where ev.session == id:
                        let pick = req.questions.first?.options.first?.id ?? "allow_once"
                        let out = try? await p.respond(to: req, with: Response(pick))
                        await tally.answer()
                        print("LIVE drive: answered request \(req.id) with \(pick) -> \(String(describing: out))")
                    case .changed(let s) where s.id == id && s.state.isFinished:
                        await tally.finish(); return
                    case .failed(let r) where ev.session == id:
                        await tally.fail(r); return
                    default: break
                    }
                    if Date() > deadline { return }
                }
            }
        }
        // Belt and braces: the stream missing a terminal transition is the exact
        // class of bug the live findings page recorded, so poll the record too.
        while await !tally.finished && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let s = try await p.refine(id)
            print("LIVE drive: refine -> \(s.state) title=\(s.title.prefix(40))")
            if s.state.isFinished { await tally.finish() }
            if let req = try await p.request(id) {
                let pick = req.questions.first?.options.first?.id ?? "allow_once"
                _ = try? await p.respond(to: req, with: Response(pick)); await tally.answer()
                print("LIVE drive: answered (poll) \(req.id) with \(pick)")
            }
            if let f = await tally.failure { XCTFail("agent failed: \(f)"); break }
        }
        streamTask?.cancel()
        let finished = await tally.finished, answered = await tally.answer_(), events = await tally.events_()
        XCTAssertTrue(finished, "agent did not finish within the deadline")

        let turns = try await p.transcript(id)
        let agentTurns = turns.filter { $0.role == .agent && !$0.text.isEmpty }
        print("LIVE drive: events=\(events) answered=\(answered) turns=\(turns.count) agentTurns=\(agentTurns.count)")
        XCTAssertGreaterThan(agentTurns.count, 0, "no agent text in the transcript")
        print("LIVE drive: last agent said: \(agentTurns.last?.text.prefix(120) ?? "")")

        let after = try String(contentsOfFile: toy + "/greet.py", encoding: .utf8)
        XCTAssertNotEqual(before, after, "greet.py did not change on disk")
        XCTAssertTrue(after.contains("\"\"\"") || after.contains("'''"), "no docstring landed")
        print("LIVE drive: greet.py now:\n\(after)")
    }
}
