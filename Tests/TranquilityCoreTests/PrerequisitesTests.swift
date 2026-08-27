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

    private func probes(
        tmux: String? = "/opt/homebrew/bin/tmux",
        hooks: String? = nil,
        secrets: Set<Secrets.Key> = Set(Secrets.Key.allCases)
    ) -> Prerequisites.Probes {
        Prerequisites.Probes(
            tmuxPath: { tmux },
            hooksProblem: { hooks },
            hasSecret: { secrets.contains($0) })
    }

    private func state(_ states: [Prerequisites.State],
                       _ item: Prerequisites.Item) -> Prerequisites.State {
        states.first { $0.item == item }!
    }

    // MARK: - the gate

    func testOnlyTmuxAndHooksHoldTheGate() {
        XCTAssertEqual(
            Set(Prerequisites.Item.allCases.filter(\.isRequired)), [.tmux, .hooks])
    }

    func testMissingTmuxBlocks() {
        let states = Prerequisites.snapshot(probes(tmux: nil))
        XCTAssertFalse(state(states, .tmux).satisfied)
        XCTAssertFalse(Prerequisites.allRequiredSatisfied(states))
    }

    /// The distinction the type exists to draw: recommended is not required.
    func testMissingKeysNeverBlock() {
        let states = Prerequisites.snapshot(probes(secrets: []))
        XCTAssertFalse(state(states, .anthropicKey).satisfied)
        XCTAssertFalse(state(states, .elevenLabsKey).satisfied)
        XCTAssertFalse(state(states, .assemblyAIKey).satisfied)
        XCTAssertTrue(Prerequisites.allRequiredSatisfied(states),
                      "an absent API key must not hold the Start door shut")
    }

    func testAnthropicIsTheRecommendedOne() {
        XCTAssertTrue(Prerequisites.Item.anthropicKey.isRecommended)
        XCTAssertEqual(Prerequisites.Item.allCases.filter(\.isRecommended), [.anthropicKey])
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
        for item in Prerequisites.Item.allCases where item.secret != nil {
            let detail = state(states, item).detail
            XCTAssertTrue(detail.lowercased().contains("without it"),
                          "\(item) says '\(detail)'")
        }
    }

    func testHookProblemDropsItsRedundantPrefix() {
        let states = Prerequisites.snapshot(probes(hooks: "hooks: 2 not installed"))
        XCTAssertEqual(state(states, .hooks).detail, "2 not installed")
    }

    func testHookProblemWithoutThePrefixPassesThrough() {
        let states = Prerequisites.snapshot(probes(hooks: "settings unreadable"))
        XCTAssertEqual(state(states, .hooks).detail, "settings unreadable")
    }

    // MARK: - which rows are drawn

    func testHealthyHooksAreNotDrawn() {
        // The app repairs hooks at launch, so a healthy row is furniture
        // reporting that nothing happened.
        let visible = Prerequisites.visible(Prerequisites.snapshot(probes()))
        XCTAssertFalse(visible.contains { $0.item == .hooks })
    }

    func testBrokenHooksAreDrawn() {
        let visible = Prerequisites.visible(
            Prerequisites.snapshot(probes(hooks: "hooks: 2 not installed")))
        XCTAssertTrue(visible.contains { $0.item == .hooks })
    }

    func testTmuxAndTheKeysAreAlwaysDrawn() {
        let visible = Prerequisites.visible(Prerequisites.snapshot(probes()))
        XCTAssertEqual(visible.map(\.item), [.tmux, .anthropicKey, .elevenLabsKey, .assemblyAIKey])
    }

    // MARK: - the links

    /// A row that says "add a key" without saying where to get one has handed
    /// the user a search, which is what this screen exists to stop doing.
    func testEveryKeyRowCarriesASignupLink() {
        for item in Prerequisites.Item.allCases where item.secret != nil {
            XCTAssertNotNil(item.signupURL, "\(item) has no signup URL")
            XCTAssertEqual(item.signupURL?.scheme, "https", "\(item) link is not https")
        }
    }

    func testNonKeyRowsHaveNoLinkOrSecret() {
        for item in [Prerequisites.Item.tmux, .hooks] {
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
        for item in Prerequisites.Item.allCases {
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
