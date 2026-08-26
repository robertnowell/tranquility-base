import Foundation
import XCTest
@testable import TranquilityCore

/// Per-harness launch settings (App-lane, default launcher, 25 Aug): each
/// harness gets its own command and directory, one of them is the default,
/// and a file written before this shape existed still reads correctly.
final class AgentDefaultsTests: XCTestCase {

    private var savedURL: URL!
    private let claude = ClaudeCodeAdapter().id
    private let codex = CodexAdapter().id

    override func setUp() {
        super.setUp()
        savedURL = AgentDefaults.fileURL
        AgentDefaults.fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-defaults-\(UUID().uuidString).json")
    }

    override func tearDown() {
        AgentDefaults.fileURL = savedURL
        super.tearDown()
    }

    func testMissingFileFallsBackPerHarness() {
        XCTAssertEqual(AgentDefaults.load(for: claude), AgentDefaults.fallback)
        XCTAssertEqual(AgentDefaults.load(for: codex), AgentDefaults.codexFallback)
        XCTAssertEqual(AgentDefaults.defaultHarness, claude)
    }

    func testEachHarnessSavesIndependently() {
        AgentDefaults.save("claude --custom-flag", for: claude)
        AgentDefaults.save("codex --custom-flag", for: codex)
        XCTAssertEqual(AgentDefaults.load(for: claude), "claude --custom-flag")
        XCTAssertEqual(AgentDefaults.load(for: codex), "codex --custom-flag")

        AgentDefaults.save(directory: "/tmp", for: claude)
        AgentDefaults.save(directory: "/var", for: codex)
        XCTAssertEqual(AgentDefaults.directoryAsTyped(for: claude), "/tmp")
        XCTAssertEqual(AgentDefaults.directoryAsTyped(for: codex), "/var")
    }

    /// Saving one harness's command must not touch the other's, or a stray
    /// entry disappears the moment its sibling is edited.
    func testSavingOneHarnessDoesNotClobberTheOther() {
        AgentDefaults.save("claude --one", for: claude)
        AgentDefaults.save("codex --one", for: codex)
        AgentDefaults.save("claude --two", for: claude)
        XCTAssertEqual(AgentDefaults.load(for: claude), "claude --two")
        XCTAssertEqual(AgentDefaults.load(for: codex), "codex --one")
    }

    func testDefaultHarnessRoundTrips() {
        AgentDefaults.defaultHarness = codex
        XCTAssertEqual(AgentDefaults.defaultHarness, codex)
    }

    /// The no-argument API every pre-25-Aug call site uses must track
    /// whichever harness is currently default, not always Claude Code.
    func testNoArgumentAPIFollowsTheDefaultHarness() {
        AgentDefaults.save("claude --mine", for: claude)
        AgentDefaults.save("codex --mine", for: codex)
        XCTAssertEqual(AgentDefaults.load(), "claude --mine")

        AgentDefaults.defaultHarness = codex
        XCTAssertEqual(AgentDefaults.load(), "codex --mine")

        AgentDefaults.save("codex --changed")
        XCTAssertEqual(AgentDefaults.load(for: codex), "codex --changed")
        XCTAssertEqual(AgentDefaults.load(for: claude), "claude --mine",
                       "saving through the no-arg API must still only touch the default harness")
    }

    /// A stored EMPTY command is unset, not honored — the same rule the old
    /// flat shape had, still true per harness.
    func testAnEmptySavedCommandReadsAsUnset() {
        AgentDefaults.save("", for: codex)
        XCTAssertEqual(AgentDefaults.load(for: codex), AgentDefaults.codexFallback)
    }

    /// A directory that does not exist falls back rather than being honored
    /// — but stays visible, as typed, in directoryAsTyped.
    func testANonexistentDirectoryFallsBackButStaysVisibleAsTyped() {
        AgentDefaults.save(directory: "/nowhere/that/exists", for: codex)
        XCTAssertEqual(AgentDefaults.directory(for: codex), AgentDefaults.fallbackDirectory)
        XCTAssertEqual(AgentDefaults.directoryAsTyped(for: codex), "/nowhere/that/exists")
    }

    /// A file written before harnesses existed — one flat command/directory,
    /// no `byHarness` or `defaultHarness` keys — must still read correctly,
    /// as Claude Code's entry, with Claude Code as the default. Nobody's
    /// upgrade may silently change what a bare New Agent press launches.
    func testAnOldFlatShapeFileMigratesToClaudeCode() throws {
        let old = """
        {"command":"claude --old-flag","directory":"/old/path"}
        """
        try old.write(to: AgentDefaults.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(AgentDefaults.defaultHarness, claude)
        XCTAssertEqual(AgentDefaults.load(for: claude), "claude --old-flag")
        XCTAssertEqual(AgentDefaults.directoryAsTyped(for: claude), "/old/path")
        // Codex is untouched by the old file — it gets its own fresh fallback,
        // not a copy of whatever Claude Code happened to have configured.
        XCTAssertEqual(AgentDefaults.load(for: codex), AgentDefaults.codexFallback)
        XCTAssertEqual(AgentDefaults.load(), "claude --old-flag")
    }

    /// Once a migrated file is saved again, it's in the new shape for good —
    /// re-reading it must not re-migrate (which would silently drop a Codex
    /// entry written in the meantime back onto a stale flat reading).
    func testASavedMigratedFileStaysInTheNewShape() throws {
        let old = """
        {"command":"claude --old-flag"}
        """
        try old.write(to: AgentDefaults.fileURL, atomically: true, encoding: .utf8)
        _ = AgentDefaults.load(for: claude)   // read-only; must not itself migrate on disk
        AgentDefaults.save("codex --new", for: codex)

        XCTAssertEqual(AgentDefaults.load(for: claude), "claude --old-flag")
        XCTAssertEqual(AgentDefaults.load(for: codex), "codex --new")
    }
}
