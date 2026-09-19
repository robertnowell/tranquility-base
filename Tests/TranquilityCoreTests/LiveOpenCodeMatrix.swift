import XCTest
@testable import TranquilityCore

/// The case matrix, driven live. Every method is one situation a user can put
/// the OpenCode provider in. Gated like the other live probes; inert in CI.
final class LiveOpenCodeMatrix: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var base: URL { URL(string: env["TB_LIVE_OPENCODE"]!)! }
    private var toy: String { env["TB_TOY"]! }
    override func setUpWithError() throws {
        try XCTSkipIf(env["TB_LIVE_OPENCODE"] == nil || env["TB_TOY"] == nil, "set TB_LIVE_OPENCODE and TB_TOY")
    }
    private func provider(_ url: URL? = nil, password: String? = nil) -> LocalOpenCodeProvider {
        LocalOpenCodeProvider(client: OpenCodeClient(
            transport: HTTPTransport(base: url ?? base, password: password, trace: { _ in }),
            provider: "opencode"))
    }
    /// Poll until finished, answering any request with `pick`. Returns (answered, finalState).
    private func drive(_ p: LocalOpenCodeProvider, _ id: AgentSession.ID, pick: String, seconds: Int = 120) async throws -> (Int, AgentSessionState, [String]) {
        var answered = 0, asked: [String] = []
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            if let req = try await p.request(id) {
                asked.append(req.questions.first?.asked ?? "?")
                _ = try await p.respond(to: req, with: Response(pick)); answered += 1
            }
            let s = try await p.refine(id)
            if s.state.isFinished { return (answered, s.state, asked) }
        }
        return (answered, try await p.refine(id).state, asked)
    }

    func test01_AuthWithPasswordWorksAndWithoutItFailsLoudly() async throws {
        guard let a = env["TB_LIVE_OPENCODE_AUTH"] else { throw XCTSkip("set TB_LIVE_OPENCODE_AUTH=http://127.0.0.1:4098") }
        let good = provider(URL(string: a)!, password: "probe-pass")
        _ = try await good.mine()
        let bad = provider(URL(string: a)!, password: nil)
        do { _ = try await bad.mine(); XCTFail("no password was accepted") }
        catch { print("MATRIX auth: without password -> \(error)") }
    }

    func test02_PermissionRejectLeavesTheFileAlone() async throws {
        let p = provider(); let before = try String(contentsOfFile: toy + "/greet.py", encoding: .utf8)
        let id = try await p.start(Brief(prompt: "Add a docstring to greet() in greet.py. If you cannot edit, reply with the single word BLOCKED."))
        let (answered, state, asked) = try await drive(p, id, pick: "reject")
        let after = try String(contentsOfFile: toy + "/greet.py", encoding: .utf8)
        print("MATRIX reject: answered=\(answered) state=\(state) asked=\(asked)")
        XCTAssertGreaterThan(answered, 0, "no permission was raised to reject")
        XCTAssertEqual(before, after, "a rejected edit still landed")
        XCTAssertTrue(state.isFinished)
    }

    func test03_PermissionAlwaysIsNotAskedTwice() async throws {
        let p = provider()
        let id = try await p.start(Brief(prompt: "Add a docstring to greet() in greet.py, reply DONE."))
        let (a1, _, _) = try await drive(p, id, pick: "always")
        _ = try await p.send("Now also add a docstring to the module at the top of greet.py, reply DONE.", to: id)
        let (a2, state, _) = try await drive(p, id, pick: "always")
        print("MATRIX always: first=\(a1) second=\(a2) state=\(state)")
        XCTAssertGreaterThan(a1, 0); XCTAssertEqual(a2, 0, "always was not honoured on the second edit")
    }

    func test04_BashPermissionIsAskedAndAnswered() async throws {
        let p = provider()
        let id = try await p.start(Brief(prompt: "Run the shell command `ls` in this directory and reply with the file names you saw."))
        let (answered, state, asked) = try await drive(p, id, pick: "once")
        print("MATRIX bash: answered=\(answered) state=\(state) asked=\(asked)")
        XCTAssertGreaterThan(answered, 0, "no bash permission was raised"); XCTAssertTrue(state.isFinished)
        XCTAssertTrue(asked.joined().lowercased().contains("bash"), asked.joined())
    }

    func test05_AQuestionFromTheAgentIsAnsweredOnTheQuestionRoute() async throws {
        let p = provider()
        let id = try await p.start(Brief(prompt: "Before doing anything, use your question tool to ask me which greeting word to use, offering the options Hello and Hi. Then reply with the word I chose and stop. Do not edit files."))
        var sawQuestion = false
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            if let req = try await p.request(id) {
                let q = req.questions.first
                let isQuestion = !(q?.options.contains { $0.kind == .allowOnce } ?? false)
                print("MATRIX question: asked=\(q?.asked ?? "?") options=\(q?.options.map(\.label) ?? []) isQuestion=\(isQuestion)")
                if isQuestion { sawQuestion = true; _ = try await p.respond(to: req, with: Response(q?.options.first?.id ?? "Hello")) }
                else { _ = try await p.respond(to: req, with: Response("reject")) }
            }
            if try await p.refine(id).state.isFinished { break }
        }
        let text = try await p.transcript(id).filter { $0.role == .agent }.map(\.text).joined(separator: " | ")
        print("MATRIX question: sawQuestion=\(sawQuestion) agent said: \(text.prefix(160))")
        if !sawQuestion { print("MATRIX question: the model did not use the question tool; route untested this run") }
    }

    func test06_AnUnreachableServerReadsAsUnknownNeverIdle() async throws {
        let p = provider(URL(string: "http://127.0.0.1:4099")!)
        let known = try await provider().mine()
        let digests = Dictionary(uniqueKeysWithValues: known.map { ($0.id, AgentPoll.digest($0)) })
        let out = await AgentPoll.refresh(p, from: digests)
        guard case .unreachable(let reason, let stale) = out else { return XCTFail("\(out)") }
        print("MATRIX unreachable: reason=\(reason.prefix(80)) stale=\(stale.count)")
        XCTAssertFalse(reason.isEmpty); XCTAssertEqual(Set(stale), Set(digests.keys))
    }

    func test07_CancelIsRefusedNotFaked() async throws {
        let p = provider(); let id = try await p.start(Brief(prompt: ""))
        let out = try await p.cancel(id); print("MATRIX cancel: \(out)")
        XCTAssertEqual(out, .unsupported)
    }

    func test08_ASessionStartedOutsideIsAdopted() async throws {
        var req = URLRequest(url: base.appendingPathComponent("session")); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type"); req.httpBody = Data("{}".utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let raw = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String ?? ""
        var m = URLRequest(url: base.appendingPathComponent("session/\(raw)/message")); m.httpMethod = "POST"
        m.setValue("application/json", forHTTPHeaderField: "content-type")
        m.httpBody = Data(#"{"parts":[{"type":"text","text":"Reply with the single word ADOPTED."}]}"#.utf8)
        _ = try await URLSession.shared.data(for: m)
        let p = provider(); let id = AgentSession.id(raw, provider: "opencode")
        let mine = try await p.mine(); let row = mine.first { $0.id == id }
        let turns = try await p.transcript(id).filter { $0.role == .agent }
        print("MATRIX adopt: present=\(row != nil) state=\(String(describing: row?.state)) title=\(row?.title.prefix(40) ?? "") agentTurns=\(turns.count)")
        XCTAssertNotNil(row); XCTAssertTrue(turns.contains { $0.text.contains("ADOPTED") })
    }

    func test09_TwoSessionsStayApart() async throws {
        let p = provider()
        let a = try await p.start(Brief(prompt: "Reply with the single word ALPHA.")); let b = try await p.start(Brief(prompt: "Reply with the single word BETA."))
        _ = try await drive(p, a, pick: "once", seconds: 60); _ = try await drive(p, b, pick: "once", seconds: 60)
        let ta = try await p.transcript(a).map(\.text).joined(), tb = try await p.transcript(b).map(\.text).joined()
        print("MATRIX two: a has ALPHA=\(ta.contains("ALPHA")) BETA=\(ta.contains("BETA")); b has BETA=\(tb.contains("BETA")) ALPHA=\(tb.contains("ALPHA"))")
        XCTAssertNotEqual(a, b); XCTAssertTrue(ta.contains("ALPHA") && !ta.contains("BETA")); XCTAssertTrue(tb.contains("BETA") && !tb.contains("ALPHA"))
    }

    func test10_ALongTurnStreamsSeveralSaidEventsThenCompletes() async throws {
        let p = provider()
        actor Seen { var said = 0; var completed = false; func s() { said += 1 }; func c() { completed = true } }
        let seen = Seen()
        guard let stream = p.changes() else { return XCTFail("no stream") }
        let id = try await p.start(Brief(prompt: ""))
        let reader = Task { for await ev in stream where ev.session == id { switch ev.kind { case .said: await seen.s(); case .changed(let s) where s.state.isFinished: await seen.c(); default: break } } }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        _ = try await p.send("Write three separate short paragraphs, each about a different planet, one message each if you can. Do not edit files.", to: id)
        _ = try await drive(p, id, pick: "once", seconds: 90); try await Task.sleep(nanoseconds: 2_000_000_000); reader.cancel()
        let said = await seen.said, completed = await seen.completed
        print("MATRIX long: said=\(said) completedOnStream=\(completed)")
        XCTAssertGreaterThan(said, 0); XCTAssertTrue(completed, "the terminal transition never reached the stream")
    }
}
