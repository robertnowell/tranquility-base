import XCTest
@testable import TranquilityCore

/// The rule texts agents read say one thing (30 Sep 2026).
///
/// The audit found 14 pairs of components each holding their own copy of a
/// rule, and the bundled share-as-page skill still taught the 8-character
/// folder that nothing uploads while the session hook said the full id. These
/// tests read the texts that ship to agents and fail on the retired rules, and
/// drive the two hooks the way a harness does.
final class RulesConsistencyTests: XCTestCase {
    /// The repository root, from this file's own path.
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Everything an agent is shown: skill texts, reference texts, the OpenCode
    /// plugin, and the hooks' non-comment lines (a comment explaining history
    /// is not an instruction).
    private func shippedText() throws -> [(String, String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        for part in ["skills", "opencode", "hooks"] {
            let base = repo.appendingPathComponent(part)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                let ext = url.pathExtension
                guard ["md", "txt", "js", "sh", "py"].contains(ext),
                      !url.path.contains("__pycache__") else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    switch ext {
                    case "sh", "py": return !t.hasPrefix("#")
                    case "js": return !t.hasPrefix("//")
                    default: return true
                    }
                }
                out.append((url.path.replacingOccurrences(of: repo.path + "/", with: ""), lines.joined(separator: "\n")))
            }
        }
        return out
    }

    func testNoShippedTextTeachesTheShortFolder() throws {
        let retired = RulesStore.retiredPhrases
        var hits: [String] = []
        for (path, text) in try shippedText() {
            for phrase in retired where text.range(of: phrase, options: .caseInsensitive) != nil {
                hits.append("\(path): \(phrase)")
            }
        }
        XCTAssertEqual(hits, [], "a retired rule is back in text agents read")
    }

    func testTheSessionHookCarriesNoSecondCopyOfTheShapeText() throws {
        let hook = try String(contentsOf: repo.appendingPathComponent("hooks/visual-output-hook.sh"), encoding: .utf8)
        XCTAssertFalse(hook.contains("THE SHAPE OF THE PAGE. Three levels"),
                       "shape-context.txt is the one copy")
    }

    func testAPersonsOwnSkillWithARetiredRuleIsNamedAndOursAreNot() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vd-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, body) in [("deep-research", "append the first dash-separated piece of your session id"),
                             ("gsap", "animation"), ("share-as-page", "agents/SHORT (ours, handled by the repair)")] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            try body.write(to: dir.appendingPathComponent(name + "/SKILL.md"), atomically: true, encoding: .utf8)
        }
        let hits = RulesStore.skillsStatingRetiredRules(in: [dir], ours: Set(SkillManifest.expected.map(\.name)))
        XCTAssertEqual(hits.map { ($0 as NSString).lastPathComponent }, ["deep-research"])
    }

    /// 30 Sep: hq-open found its Hub window by walking up to the .app around
    /// itself. Run from the rules store there is none, so every page opened
    /// in the browser. From the store it must reach the app the running app
    /// recorded.
    func testHqOpenInTheStoreFindsTheRecordedApp() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vd-store-\(UUID().uuidString)/rules")
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let scripts = root.appendingPathComponent("versions/abc/skills/research-hq/scripts")
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        try fm.copyItem(at: repo.appendingPathComponent("skills/research-hq/scripts/hq-open"),
                        to: scripts.appendingPathComponent("hq-open"))
        func ownApp() throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-c", """
                import importlib.machinery, importlib.util, sys
                loader = importlib.machinery.SourceFileLoader("hqopen", sys.argv[1])
                m = importlib.util.module_from_spec(importlib.util.spec_from_loader("hqopen", loader)); loader.exec_module(m)
                print(m.own_app())
                """, scripts.appendingPathComponent("hq-open").path]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try ownApp(), "None", "nothing recorded: the browser")
        RulesStore.recordApp(bundleID: "com.example.tb.dev",
                             bundlePath: "/private/var/folders/x/AppTranslocation/y/TB.app", root: root)
        XCTAssertEqual(try ownApp(), "('id', 'com.example.tb.dev')", "a translocated path is never recorded")
    }

    /// 30 Sep: a MacBook report carried the brief's markup and none of its
    /// stylesheet, outside the agents folder. Ruled a context problem, not a
    /// gate: the page hook tells the agent what is wrong and how to redo it,
    /// never rewrites the page, and logs the case for the hourly report. (The
    /// hook ignores temp folders by design, so this runs in a scratch folder
    /// under the real home and removes it.)
    func testThePageHookTellsTheAgentAndLogsButNeverRewrites() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent(".tb-style-drill-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let sid = "11111111-2222-4333-8444-555566667777"
        let outside = home.appendingPathComponent("ClaudeWork/replay-eval/judge_body.html")
        try fm.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        let words = Array(repeating: "word", count: 150).joined(separator: " ")
        let original = """
            <!doctype html><html><head><meta charset="utf-8"><title>T</title></head><body><main>
            <h1>Three reviewers, one verifier.</h1><p class="lede"><b>Claim.</b> More.</p>
            <div class="you"><p>Two decisions.</p></div>
            <details open><summary><span class="c">Reviewers differ.</span></summary><div class="d"><p>\(words)</p></div></details>
            </main></body></html>
            """
        try original.write(to: outside, atomically: true, encoding: .utf8)
        let payload = "{\"session_id\":\"\(sid)\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"\(outside.path)\"}}"
        let said = try run("artifact-hook.sh", stdin: payload, env: ["HOME": home.path])
        XCTAssertTrue(said.contains("THIS PAGE WILL NOT WORK"), said)
        XCTAssertTrue(said.contains("not its stylesheet") && said.contains("outside your agent folder"), said)
        XCTAssertTrue(said.contains("hq-page new"))
        XCTAssertFalse(try String(contentsOf: outside, encoding: .utf8).contains(".you{"), "the page is never rewritten")
        let log = try String(contentsOf: home.appendingPathComponent(
            "Library/Application Support/VoiceDispatch/rules/page-problems.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("no-house-style,outside-agent-folder") && log.contains(outside.path))
    }

    /// 30 Sep (Robert): nudge only about OUR reports. Plain open on one of
    /// them is named and logged; plain open on a Gmail draft, `open -a`, or a
    /// URL hears nothing; a non-report HTML file written outside the agents
    /// folder hears nothing; an editorial (non-brief) report of ours outside
    /// the folder is told only that it is outside.
    func testOnlyOurOwnPagesGetANudge() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent(".tb-nudge-drill-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let sid = "11111111-2222-4333-8444-555566667777"
        let work = home.appendingPathComponent("ClaudeWork")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let words = Array(repeating: "word", count: 150).joined(separator: " ")
        let ours = work.appendingPathComponent("report.html")
        try "<html><head><style>.you{}</style></head><body><p class=\"lede\">x</p><div class=\"you\">y</div><p>\(words)</p></body></html>"
            .write(to: ours, atomically: true, encoding: .utf8)
        let gmail = work.appendingPathComponent("newsletter.html")
        try "<html><body><table><tr><td>Hello from the newsletter \(words)</td></tr></table></body></html>"
            .write(to: gmail, atomically: true, encoding: .utf8)
        let editorial = work.appendingPathComponent("essay.html")
        try "<html><head><meta name=\"intranet:session\" content=\"\(sid)\"></head><body><article><p>\(words)</p></article></body></html>"
            .write(to: editorial, atomically: true, encoding: .utf8)
        func bash(_ command: String) throws -> String {
            let payload = String(data: try JSONSerialization.data(withJSONObject: [
                "session_id": sid, "hook_event_name": "PostToolUse", "tool_name": "Bash",
                "tool_input": ["command": command], "cwd": work.path]), encoding: .utf8)!
            return try run("artifact-hook.sh", stdin: payload, env: ["HOME": home.path])
        }
        func write(_ url: URL) throws -> String {
            let payload = String(data: try JSONSerialization.data(withJSONObject: [
                "session_id": sid, "hook_event_name": "PostToolUse", "tool_name": "Write",
                "tool_input": ["file_path": url.path]]), encoding: .utf8)!
            return try run("artifact-hook.sh", stdin: payload, env: ["HOME": home.path])
        }
        XCTAssertTrue(try bash("open report.html").contains("OPENED AS A LOCAL FILE"))
        XCTAssertFalse(try bash("open newsletter.html").contains("OPENED AS A LOCAL FILE"), "not ours: silent")
        XCTAssertFalse(try bash("open -a Safari report.html").contains("OPENED AS A LOCAL FILE"), "an app, not plain open")
        XCTAssertFalse(try bash("open https://hq.tranquilitybase.dev/d/x").contains("OPENED AS A LOCAL FILE"))
        XCTAssertFalse(try write(gmail).contains("THIS PAGE WILL NOT WORK"), "other HTML is never judged")
        let essay = try write(editorial)
        XCTAssertTrue(essay.contains("outside your agent folder") && !essay.contains("not its stylesheet"), essay)
        let log = try String(contentsOf: home.appendingPathComponent(
            "Library/Application Support/VoiceDispatch/rules/page-problems.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("plain-open") && log.contains(ours.path))
        XCTAssertFalse(log.contains(gmail.path))
    }

    // MARK: - The hooks, driven as a harness drives them

    private func run(_ script: String, stdin: String, env: [String: String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [repo.appendingPathComponent("hooks/" + script).path]
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data(stdin.utf8)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testARunningSessionGetsTheRulesOnceThenAgainOnlyWhenTheyChange() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vd-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["HOME": home.path, "CLAUDE_CODE_ENTRYPOINT": "cli"]
        let sid = "11111111-2222-4333-8444-555566667777"
        let prompt = "{\"session_id\":\"\(sid)\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"hi\"}"

        let version = try run("visual-output-hook.sh", stdin: "", env: env.merging(["TB_RULES_VERSION_ONLY": "1"]) { $1 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(version.count, 12)

        let first = try run("tbase-hook.sh", stdin: prompt, env: env)
        XCTAssertTrue(first.contains("\"UserPromptSubmit\"") && first.contains("Rules version \(version)"),
                      "a session with no recorded version is told the rules")
        XCTAssertEqual(try run("tbase-hook.sh", stdin: prompt, env: env), "", "and not twice")

        let seen = home.appendingPathComponent("Library/Application Support/VoiceDispatch/rules/seen/\(sid)")
        try "an older version".write(to: seen, atomically: true, encoding: .utf8)
        XCTAssertTrue(try run("tbase-hook.sh", stdin: prompt, env: env).contains("Rules version \(version)"),
                      "a rule change reaches the running session at its next prompt")
    }

    func testTheSessionHookRecordsTheVersionItSent() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vd-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sid = "aaaaaaaa-2222-4333-8444-555566667777"
        let out = try run("visual-output-hook.sh", stdin: "{\"session_id\":\"\(sid)\"}",
                          env: ["HOME": home.path, "CLAUDE_CODE_ENTRYPOINT": "cli", "TB_SKIP_HUBLINES": "1"])
        XCTAssertTrue(out.contains(home.path + "/Documents/agents/" + sid), "the full id, named in full")
        let seen = try String(contentsOf: home.appendingPathComponent(
            "Library/Application Support/VoiceDispatch/rules/seen/\(sid)"), encoding: .utf8)
        XCTAssertTrue(out.contains("Rules version \(seen)"))
    }
}
