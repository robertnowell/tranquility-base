import XCTest
@testable import TranquilityCore

/// The first-run install, from a machine that is not a developer's.
///
/// Every failure asserted here was live on 1 Sep on a shipped build, and not one
/// of them could reproduce in this repo before that day, because the repo IS the
/// thing that hides them: the hooks live at `~/Projects/tranquility-base/hooks`,
/// which has no space in it, and the keys in the login keychain are real ones
/// that were typed years ago rather than pasted this minute.
///
/// So the fixture here is the shipped path, spaces and all.
final class FirstRunInstallTests: XCTestCase {

    /// The bundled hooks directory on any machine that installed the app.
    private let bundled = "/Applications/Tranquility Base.app/Contents/Resources/hooks"

    // MARK: - A path with a space in it

    /// The audit's half. `split(separator: " ").first` asked whether
    /// `/Applications/Tranquility` existed and reported five healthy hooks as
    /// `brokenPath`, on every install that was not a checkout.
    func testTheExecutableOfACommandSurvivesASpace() {
        let script = bundled + "/tbase-hook.sh"
        XCTAssertEqual(HookManifest.executable(inCommand: "'\(script)'"), script)
        XCTAssertEqual(HookManifest.executable(inCommand: "\"\(script)\""), script)
    }

    /// A plain path is still a plain path. The quoting is conditional, so an
    /// existing healthy install is never rewritten just to add quotes, and the
    /// developer case has to keep working unchanged.
    func testAPathWithoutASpaceIsLeftAlone() {
        let plain = "/Users/x/Projects/tranquility-base/hooks/tbase-hook.sh"
        XCTAssertEqual(HookManifest.command(forScript: plain), plain)
        XCTAssertEqual(HookManifest.executable(inCommand: plain), plain)
    }

    /// The repair's half: what gets WRITTEN has to survive the shell the
    /// harness runs it in. Unquoted, `sh -c` executes `/Applications/Tranquility`
    /// with an argument, so the hooks would not have fired even once the audit
    /// stopped lying about them.
    func testABundledPathIsWrittenQuoted() {
        let written = HookManifest.command(forScript: bundled + "/tbase-hook.sh")
        XCTAssertTrue(written.hasPrefix("'"), "a path with a space must be quoted")
        XCTAssertEqual(HookManifest.executable(inCommand: written),
                       bundled + "/tbase-hook.sh")
    }

    func testAQuoteInsideAPathIsEscapedAndReadBack() {
        let awkward = "/Users/x/it's here/hooks/tbase-hook.sh"
        let written = HookManifest.command(forScript: awkward)
        XCTAssertEqual(HookManifest.executable(inCommand: written), awkward)
    }

    /// The shape this app itself wrote into every bundled install before the
    /// fix: a raw path with a space, no quotes. It has to be READ correctly, or
    /// the upgrade that repairs it reports the same broken audit forever.
    func testARawPathWithASpaceIsReadFromDiskRatherThanGuessedAt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Tranquility Base \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("tbase-hook.sh")
        try "#!/bin/bash\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)

        XCTAssertEqual(HookManifest.executable(inCommand: script.path), script.path)
    }

    /// And the whole loop: a settings file carrying raw bundled paths is
    /// audited as broken, repaired into quoted ones, and audits clean. This is
    /// the sequence that produced "5 pointing at a missing file" and then
    /// "scripts missing at /Applications/Tranquility Base.app/..." on a machine
    /// where all three scripts were present and executable.
    func testAnInstallWithSpacesRepairsInsteadOfRepeatingItself() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-space-\(UUID().uuidString)", isDirectory: true)
        let hooks = root.appendingPathComponent("Tranquility Base.app/Contents/Resources/hooks",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for script in HookManifest.allScripts() {
            let path = hooks.appendingPathComponent(script)
            try "#!/bin/bash\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        // Written the way the shipped app wrote it: raw, unquoted, with a space.
        var wiring: [String: Any] = [:]
        for hook in HookManifest.expected {
            var entry: [String: Any] = ["hooks": [[
                "type": "command",
                "command": hooks.appendingPathComponent(hook.script).path,
                "timeout": 5,
            ]]]
            if let matcher = hook.matcher { entry["matcher"] = matcher }
            var entries = wiring[hook.event] as? [[String: Any]] ?? []
            entries.append(entry)
            wiring[hook.event] = entries
        }
        let settings = root.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["hooks": wiring], options: [])
            .write(to: settings)

        // Before: NOT "5 pointing at a missing file". The files are all there;
        // what is wrong is that a shell cannot run them from this spelling.
        let before = try XCTUnwrap(HookManifest.problemSummary(settings: settings))
        XCTAssertTrue(before.contains("the harness cannot run"), before)
        XCTAssertFalse(before.contains("missing file"), before)

        // The repair CHANGES something, which is the half that dead-ended: it
        // used to compute the identical raw path, find nothing to write, and
        // report "scripts missing at <a directory holding every script>".
        let outcome = HookManifest.repair(
            settings: settings, record: root.appendingPathComponent("hooks-dir"))
        guard case .repaired(let rewired, let added) = outcome else {
            return XCTFail("expected a repair, got \(outcome)")
        }
        XCTAssertEqual(rewired, HookManifest.expected.count)
        XCTAssertEqual(added, 0)
        XCTAssertNil(HookManifest.problemSummary(settings: settings))

        // And what it wrote is a command a shell runs as one word.
        let written = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: settings)) as? [String: Any])
        let stop = try XCTUnwrap((written["hooks"] as? [String: Any])?["Stop"]
            as? [[String: Any]])
        let command = try XCTUnwrap(
            ((stop[0]["hooks"] as? [[String: Any]])?[0]["command"]) as? String)
        XCTAssertTrue(command.hasPrefix("'"), command)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: HookManifest.executable(inCommand: command)))
    }

    // MARK: - A key that will not go through a header

    /// One control character anywhere in a pasted key makes an illegal HTTP
    /// header. Anthropic answers that with a bare 400 and an empty body, which
    /// `classify` reports as "unexpected reply (400)": honest about the
    /// response, and no help at all. Measured 1 Sep: every malformed KEY shape
    /// comes back 401 with a message, so a 400 was never about the credential.
    func testAPastedKeyLosesTheInvisibles() {
        XCTAssertEqual(KeyCheck.sanitize("sk-ant-api03-AAA\u{7f}BBB"), "sk-ant-api03-AAABBB")
        XCTAssertEqual(KeyCheck.sanitize(" sk-ant-api03-AAA\nBBB\t"), "sk-ant-api03-AAABBB")
        XCTAssertEqual(KeyCheck.sanitize("sk-ant-api03-AAA\u{0}"), "sk-ant-api03-AAA")
    }

    func testSanitizingLeavesAGoodKeyAlone() {
        let good = "sk-ant-api03-abcDEF123_-"
        XCTAssertEqual(KeyCheck.sanitize(good), good)
    }

    /// The endpoint has to be one the app itself calls. `/v1/user` wants
    /// `user_read`, a permission this product never uses, and refuses a
    /// text-to-speech key with a 401: a working key reported as rejected, with
    /// an alert advising the user to hunt for a stray space in it.
    func testTheElevenLabsCheckAsksForSomethingTheAppActuallyUses() throws {
        let request = try XCTUnwrap(
            KeyCheck.request(for: .elevenLabsAPIKey, value: "x"))
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("/v2/voices"), url)
        XCTAssertFalse(url.contains("/v1/user"), url)
    }

    // MARK: - A lamp that agrees with the row beside it

    func testARejectedKeyLosesItsGreenLamp() {
        let states = Prerequisites.snapshot(Prerequisites.Probes(
            tmuxPath: { "/opt/homebrew/bin/tmux" },
            hooksProblem: { nil },
            hasSecret: { _ in true },
            keyVerdict: { _ in .rejected(status: 401) }))
        let key = states.first { $0.item == .elevenLabsKey }!
        XCTAssertFalse(key.satisfied, "stored is not working")
        XCTAssertTrue(key.attention, "a refusal is the user's to fix now")
        XCTAssertEqual(key.detail, "rejected by the provider (401)")
    }

    /// The other three verdicts are not evidence against a key. A lamp that
    /// goes amber on a train is a lamp nobody trusts afterwards.
    func testAnUncheckableKeyKeepsIts() {
        for verdict: KeyCheck.Outcome in [.working, .unreachable, .unexpected(status: 500)] {
            let states = Prerequisites.snapshot(Prerequisites.Probes(
                tmuxPath: { "/opt/homebrew/bin/tmux" },
                hooksProblem: { nil },
                hasSecret: { _ in true },
                keyVerdict: { _ in verdict }))
            let key = states.first { $0.item == .anthropicKey }!
            XCTAssertTrue(key.satisfied, "\(verdict) must not unlight a stored key")
            XCTAssertFalse(key.attention)
        }
    }

    /// A key nobody has typed is quiet, not wrong. It stays grey, and it must
    /// never carry a stale verdict from the credential it replaced.
    func testAnAbsentKeyIsQuiet() {
        let states = Prerequisites.snapshot(Prerequisites.Probes(
            tmuxPath: { "/opt/homebrew/bin/tmux" },
            hooksProblem: { nil },
            hasSecret: { _ in false },
            keyVerdict: { _ in .rejected(status: 401) }))
        let key = states.first { $0.item == .assemblyAIKey }!
        XCTAssertFalse(key.satisfied)
        XCTAssertFalse(key.attention)
        XCTAssertEqual(key.detail, "without it, transcription after you stop")
    }

    func testAVerdictSurvivesARoundTrip() {
        let all: [KeyCheck.Outcome] = [
            .working, .unreachable, .rejected(status: 401), .unexpected(status: 400),
        ]
        for outcome in all {
            XCTAssertEqual(KeyVerdict.decode(KeyVerdict.encode(outcome)), outcome)
        }
        XCTAssertNil(KeyVerdict.decode("nonsense"))
        XCTAssertNil(KeyVerdict.decode("rejected:notanumber"))
    }
}
