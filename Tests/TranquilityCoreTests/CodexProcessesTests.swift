import XCTest
@testable import TranquilityCore

/// The pure halves of Codex's process-table probe: the interactive-shape
/// allowlist and the three-way liveness attribution built on top of it.
/// Fixtures below are real measured lines (22 Aug, codex-cli 0.149.0 in an
/// isolated tmux socket, and the desktop ChatGPT/Codex.app's own process
/// table entry on this machine), not invented shapes.
final class CodexProcessesTests: XCTestCase {

    // MARK: parse — the interactive allowlist

    func testParseAcceptsABareInteractiveLaunch() {
        let candidates = CodexProcesses.parse("80310 codex")
        XCTAssertEqual(candidates, [.init(pid: 80310, argv: ["codex"])])
        XCTAssertNil(candidates[0].resumingSessionId)
    }

    func testParseAcceptsAResume() {
        let line = "80310 /Users/robertnowell/.local/bin/codex resume "
            + "01a02a35-8a24-7b61-bbcb-95c107a84889"
        let candidates = CodexProcesses.parse(line)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].pid, 80310)
        XCTAssertEqual(candidates[0].resumingSessionId,
                       "01a02a35-8a24-7b61-bbcb-95c107a84889")
    }

    func testParseExcludesTheDesktopAppsOwnBundledBinary() {
        // Real line from this machine's process table: the ChatGPT desktop
        // app runs its own `codex` binary as an internal app-server. Same
        // executable name, not a CLI session TB could ever dispatch to —
        // this is the exact shape a broad `pkill -f codex` came within one
        // command of hitting during this session's own measurement work.
        let line = "7542 /Applications/Codex.app/Contents/Resources/codex "
            + "-c features.code_mode_host=true app-server --analytics-default-enabled"
        XCTAssertEqual(CodexProcesses.parse(line), [])
    }

    func testParseExcludesUnrelatedProcesses() {
        XCTAssertEqual(CodexProcesses.parse("1 /sbin/launchd"), [])
        XCTAssertEqual(CodexProcesses.parse("329 /usr/libexec/logd"), [])
    }

    func testParseExcludesAnUnmeasuredCodexSubcommand() {
        // Positive-evidence allowlist, not a blocklist: a codex invocation
        // shaped some third way (not bare, not exactly `resume <id>`) is
        // excluded even though it starts with the right binary name — this
        // repo has not measured what it is, so it does not get to count as
        // an ordinary interactive session.
        XCTAssertEqual(CodexProcesses.parse("999 codex --help"), [])
        XCTAssertEqual(CodexProcesses.parse("999 codex resume"), [])
        XCTAssertEqual(CodexProcesses.parse("999 codex resume a b"), [])
    }

    func testParseIgnoresMalformedAndEmptyLines() {
        XCTAssertEqual(CodexProcesses.parse(""), [])
        XCTAssertEqual(CodexProcesses.parse("garbage\n\nnot-a-pid codex"), [])
    }

    func testParseHandlesMultipleLines() {
        let ps = """
        80310 codex
        7542 /Applications/Codex.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
        1 /sbin/launchd
        """
        let candidates = CodexProcesses.parse(ps)
        XCTAssertEqual(candidates.map(\.pid), [80310])
    }

    // MARK: liveness — the three-way attribution

    func testLivenessMatchesByExplicitResumeId() {
        let candidates = [CodexProcesses.Candidate(
            pid: 42, argv: ["codex", "resume", "target-id"])]
        let (liveness, pid) = CodexProcesses.liveness(
            forSessionId: "target-id", cwd: "/wherever", among: candidates,
            cwdOf: { _ in nil })
        XCTAssertEqual(liveness, .live)
        XCTAssertEqual(pid, 42)
    }

    func testLivenessResumeMatchIgnoresCwdEntirely() {
        // An explicit resume match is unambiguous on its own — codex wrote
        // the id into its own argv, so a wrong or missing cwd changes
        // nothing about identity.
        let candidates = [CodexProcesses.Candidate(
            pid: 42, argv: ["codex", "resume", "target-id"])]
        let (liveness, pid) = CodexProcesses.liveness(
            forSessionId: "target-id", cwd: nil, among: candidates, cwdOf: { _ in nil })
        XCTAssertEqual(liveness, .live)
        XCTAssertEqual(pid, 42)
    }

    func testLivenessAmbiguousBareLaunchInSameDirectoryReadsAsUnknown() {
        // A fresh, unresumed `codex` process in the session's own directory
        // could BE this session or could be an unrelated one — never
        // assumed either way.
        let candidates = [CodexProcesses.Candidate(pid: 99, argv: ["codex"])]
        let (liveness, pid) = CodexProcesses.liveness(
            forSessionId: "some-id", cwd: "/Users/robertnowell/Projects/tranquility-base",
            among: candidates,
            cwdOf: { $0 == 99 ? "/Users/robertnowell/Projects/tranquility-base" : nil })
        XCTAssertEqual(liveness, .unknown)
        XCTAssertNil(pid)
    }

    func testLivenessNoCandidateInDirectoryReadsAsGone() {
        let (liveness, pid) = CodexProcesses.liveness(
            forSessionId: "some-id", cwd: "/Users/robertnowell/Projects/tranquility-base",
            among: [], cwdOf: { _ in nil })
        XCTAssertEqual(liveness, .gone)
        XCTAssertNil(pid)
    }

    func testLivenessBareLaunchInADifferentDirectoryDoesNotCount() {
        // A codex process running SOMEWHERE ELSE is not evidence about
        // THIS session — cwd is the only signal a bare launch offers, and
        // it must match exactly, not merely exist.
        let candidates = [CodexProcesses.Candidate(pid: 7, argv: ["codex"])]
        let (liveness, pid) = CodexProcesses.liveness(
            forSessionId: "some-id", cwd: "/Users/robertnowell/Projects/a",
            among: candidates, cwdOf: { $0 == 7 ? "/Users/robertnowell/Projects/b" : nil })
        XCTAssertEqual(liveness, .gone)
        XCTAssertNil(pid)
    }

    func testLivenessNilCwdWithNoResumeMatchReadsAsGone() {
        // No cwd to compare against and no explicit id match: there is
        // nothing left to call `.unknown` about.
        let candidates = [CodexProcesses.Candidate(pid: 7, argv: ["codex"])]
        let (liveness, pid) = CodexProcesses.liveness(
            forSessionId: "some-id", cwd: nil, among: candidates, cwdOf: { _ in "/anywhere" })
        XCTAssertEqual(liveness, .gone)
        XCTAssertNil(pid)
    }
}
