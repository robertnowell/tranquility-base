import XCTest
@testable import TranquilityCore

/// The keep-audio drill is the deploy-time proof that a committed capture is
/// kept and a kept file is adopted (docs/rulings/ruling-an-open-microphone-is-a-promise.md).
/// It runs on the real filesystem against a throwaway store; this test guards
/// the drill itself, so a green launch gate cannot come from a drill that
/// started erroring or quietly inverted a check.
final class KeepAudioDrillTests: XCTestCase {
    func testEveryCheckPasses() throws {
        let groups = try KeepAudioDrill.run()
        XCTAssertEqual(groups.map(\.name), ["keepAudio", "bootAdopt"])
        for group in groups {
            for check in group.checks {
                XCTAssertTrue(check.passed, "\(group.name).\(check.name) must pass")
            }
        }
    }

    /// Leaves nothing behind — the drill writes only under its own temp root.
    func testDrillLeavesNoResidueInTheTempRoot() throws {
        let before = temporaryChildCount()
        _ = try KeepAudioDrill.run()
        XCTAssertEqual(temporaryChildCount(), before,
                       "the drill must clean up its throwaway root")
    }

    private func temporaryChildCount() -> Int {
        let root = FileManager.default.temporaryDirectory
        let kids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return kids.filter { $0.hasPrefix("tb-keep-drill-") }.count
    }
}
