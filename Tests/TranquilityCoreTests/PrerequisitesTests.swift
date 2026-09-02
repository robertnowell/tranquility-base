import Foundation
import XCTest
@testable import TranquilityCore

/// The second screen's detectors.
///
/// These exist because the app layer cannot be tested (rule 7, no window server)
/// and this is the half that decides what a first-run user is told. A row that
/// reports the wrong thing is worse than no row: it sends someone to fix
/// something already fine, or says everything is ready while the loop cannot
/// deliver a single reply.
final class PrerequisitesTests: XCTestCase {

    /// Both harnesses, always, whatever this machine happens to have. The
    /// snapshot is a pure function of its probes and the tests say so.
    private static let bothHarnesses = [ClaudeCodeAdapter().id, CodexAdapter().id]

    private func probes(
        tmux: String? = "/opt/homebrew/bin/tmux",
        hooks: String? = nil,
        secrets: Set<Secrets.Key> = Set(Secrets.Key.allCases),
        harnesses: [String] = bothHarnesses
    ) -> Prerequisites.Probes {
        Prerequisites.Probes(
            tmuxPath: { tmux },
            hooksProblem: { _ in hooks },
            hasSecret: { secrets.contains($0) },
            harnesses: { harnesses })
    }

    /// The Claude Code row, which `probes()` always supplies. Named rather
    /// than discovered: a test that asks the machine which harness to talk
    /// about is a test whose subject changes with the machine.
    private var aHooksRow: Prerequisites.Item {
        .hooks(harness: ClaudeCodeAdapter().id)
    }

    private func state(_ states: [Prerequisites.State],
                       _ item: Prerequisites.Item) -> Prerequisites.State {
        states.first { $0.item == item }!
    }

    // MARK: - the gate

    /// ANTHROPIC JOINED THE GATE 1 SEP. Without that key the readout falls to
    /// the deterministic floor, which the product is not.
    func testTmuxHooksAndAnthropicHoldTheGate() {
        let required = Prerequisites.items(harnesses: Self.bothHarnesses).filter(\.isRequired)
        XCTAssertTrue(required.contains(.tmux))
        XCTAssertTrue(required.contains(.anthropicKey))
        XCTAssertFalse(required.contains(.elevenLabsKey))
        XCTAssertFalse(required.contains(.assemblyAIKey))
    }

    /// One row per harness, named for it. A machine with no harness gets none.
    func testEachDetectedHarnessGetsItsOwnRow() {
        let items = Prerequisites.items(harnesses: Self.bothHarnesses)
        let hookRows = items.compactMap { item -> String? in
            guard case .hooks(let harness) = item else { return nil }
            return harness
        }
        XCTAssertEqual(hookRows, Self.bothHarnesses)
        for item in items where item.harness != nil {
            XCTAssertTrue(item.title.hasSuffix(" hooks"), item.title)
            XCTAssertNotEqual(item.title, "Agent hooks",
                              "a hooks row has to name its harness")
        }
    }

    /// Round trip, because the button identifier is the only thing carrying a
    /// row's identity from the view back to Core.
    /// A machine with neither harness draws no hooks row at all, and is not
    /// told its Codex is broken.
    func testNoHarnessMeansNoHooksRow() {
        let states = Prerequisites.snapshot(probes(harnesses: []))
        XCTAssertFalse(states.contains { if case .hooks = $0.item { return true }; return false })
        XCTAssertTrue(Prerequisites.allRequiredSatisfied(states),
                      "nothing to wire cannot be a blocker")
    }

    func testAnItemSurvivesItsIdentifier() {
        for item in Prerequisites.items(harnesses: Self.bothHarnesses) {
            XCTAssertEqual(Prerequisites.Item(id: item.id), item, item.id)
        }
        XCTAssertNil(Prerequisites.Item(id: "nonsense"))
    }

    func testMissingTmuxBlocks() {
        let states = Prerequisites.snapshot(probes(tmux: nil))
        XCTAssertFalse(state(states, .tmux).satisfied)
        XCTAssertFalse(Prerequisites.allRequiredSatisfied(states))
    }

    /// The two that degrade honestly still never block: no key means the macOS
    /// system voice, and transcription after you stop instead of during. Both
    /// still work.
    func testTheVoiceAndTranscriptKeysNeverBlock() {
        let states = Prerequisites.snapshot(
            probes(secrets: [.anthropicAPIKey]))
        XCTAssertFalse(state(states, .elevenLabsKey).satisfied)
        XCTAssertFalse(state(states, .assemblyAIKey).satisfied)
        XCTAssertTrue(Prerequisites.allRequiredSatisfied(states),
                      "an absent voice key must not hold the Start door shut")
    }

    /// And the one that does not degrade honestly does block.
    func testAMissingAnthropicKeyBlocks() {
        let states = Prerequisites.snapshot(probes(secrets: []))
        XCTAssertFalse(state(states, .anthropicKey).satisfied)
        XCTAssertFalse(Prerequisites.allRequiredSatisfied(states),
                       "without it the readout is the deterministic floor")
    }

    // MARK: - what the rows say

    func testMissingTmuxNamesTheMachineNotTheSession() {
        // The failure this row replaces was a per-session message that read as a
        // problem with that session.
        let detail = state(Prerequisites.snapshot(probes(tmux: nil)), .tmux).detail
        XCTAssertTrue(detail.contains("not installed"), detail)
    }

    func testSatisfiedTmuxShowsWhereItFoundIt() {
        let states = Prerequisites.snapshot(probes(tmux: "/usr/local/bin/tmux"))
        XCTAssertEqual(state(states, .tmux).detail, "/usr/local/bin/tmux")
    }

    /// A missing key must say what is LOST, not merely that it is absent:
    /// the row has to be worth reading by someone deciding whether to go get one.
    func testEveryMissingKeyNamesWhatIsLost() {
        let states = Prerequisites.snapshot(probes(secrets: []))
        for item in Prerequisites.items(harnesses: Self.bothHarnesses) where item.secret != nil {
            let detail = state(states, item).detail
            XCTAssertTrue(detail.lowercased().contains("without it"),
                          "\(item) says '\(detail)'")
        }
    }

    /// The probe hands over a bare problem now, because `HookManifest.problem`
    /// strips the "hooks: " prefix at the source. The row prints it verbatim:
    /// the row is already titled with its harness, so nothing needs re-labelling
    /// on the way through.
    func testAHooksRowPrintsItsProblemVerbatim() {
        let states = Prerequisites.snapshot(probes(hooks: "2 not installed"))
        XCTAssertEqual(state(states, aHooksRow).detail, "2 not installed")
    }

    func testHookProblemWithoutThePrefixPassesThrough() {
        let states = Prerequisites.snapshot(probes(hooks: "settings unreadable"))
        XCTAssertEqual(state(states, aHooksRow).detail, "settings unreadable")
    }

    // MARK: - which rows are drawn

    /// Reversed 1 Sep. Hiding a healthy hooks row meant success deleted the
    /// only line that could have reported it, so the checklist answered "is
    /// this working?" with a gap. See `Prerequisites.visible`.
    func testHealthyHooksAreDrawnToo() {
        let visible = Prerequisites.visible(Prerequisites.snapshot(probes()))
        XCTAssertTrue(visible.contains { $0.item == aHooksRow })
    }

    func testBrokenHooksAreDrawn() {
        let visible = Prerequisites.visible(
            Prerequisites.snapshot(probes(hooks: "hooks: 2 not installed")))
        XCTAssertTrue(visible.contains { $0.item == aHooksRow })
    }

    func testTmuxAndTheKeysAreAlwaysDrawn() {
        let visible = Prerequisites.visible(Prerequisites.snapshot(probes()))
        XCTAssertEqual(visible.map(\.item),
                       Prerequisites.items(harnesses: Self.bothHarnesses))
    }

    // MARK: - the links

    /// A row that says "add a key" without saying where to get one has handed
    /// the user a search, which is what this screen exists to stop doing.
    func testEveryKeyRowCarriesASignupLink() {
        for item in Prerequisites.items(harnesses: Self.bothHarnesses) where item.secret != nil {
            XCTAssertNotNil(item.signupURL, "\(item) has no signup URL")
            XCTAssertEqual(item.signupURL?.scheme, "https", "\(item) link is not https")
        }
    }

    func testNonKeyRowsHaveNoLinkOrSecret() {
        for item in [Prerequisites.Item.tmux, aHooksRow] {
            XCTAssertNil(item.secret)
            XCTAssertNil(item.signupURL)
        }
    }

    func testEachKeyRowMapsToItsOwnKeychainEntry() {
        XCTAssertEqual(Prerequisites.Item.anthropicKey.secret, .anthropicAPIKey)
        XCTAssertEqual(Prerequisites.Item.elevenLabsKey.secret, .elevenLabsAPIKey)
        XCTAssertEqual(Prerequisites.Item.assemblyAIKey.secret, .assemblyAIAPIKey)
    }

    func testOneKeyPresentDoesNotSatisfyAnother() {
        let states = Prerequisites.snapshot(probes(secrets: [.anthropicAPIKey]))
        XCTAssertTrue(state(states, .anthropicKey).satisfied)
        XCTAssertFalse(state(states, .elevenLabsKey).satisfied)
        XCTAssertFalse(state(states, .assemblyAIKey).satisfied)
    }

    // MARK: - shape

    func testEveryItemCarriesATitleWhyAndFixLabel() {
        for item in Prerequisites.items(harnesses: Self.bothHarnesses) {
            XCTAssertFalse(item.title.isEmpty, "\(item) has no title")
            XCTAssertFalse(item.why.isEmpty, "\(item) has no why")
            XCTAssertFalse(item.fixLabel.isEmpty, "\(item) has no fix label")
        }
    }

    /// The uncached scan is what lets a row go green without a relaunch, so it
    /// must never report a path that is not actually runnable.
    func testTmuxOnDiskOnlyReportsAnExecutable() {
        if let found = Prerequisites.tmuxOnDisk() {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: found), found)
        }
        // No assertion on the nil branch: whether this machine has tmux is not
        // this test's business, and asserting either way would make it pass or
        // fail for a reason unrelated to the code.
    }
}
