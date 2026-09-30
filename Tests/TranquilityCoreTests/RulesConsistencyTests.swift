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
