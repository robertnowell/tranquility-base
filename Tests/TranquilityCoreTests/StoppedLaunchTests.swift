import XCTest
@testable import TranquilityCore

/// A launch that stops is visible — the pane says why, the log says why, and
/// a window opens on it.
///
/// The screens below are verbatim captures from 27 Aug, when Codex 0.149.0
/// began greeting every fresh pane with an update prompt and stopping there.
/// Twenty-one of twenty-two panes on the machine were on this screen; the app
/// read it fifteen times per launch and never once wrote it down.
final class StoppedLaunchTests: XCTestCase {

    /// `watch` takes non-escaping closures but the compiler cannot see that
    /// through the @Sendable trace parameter; a reference box is the tidy way
    /// to count calls without teaching the test about concurrency it doesn't do.
    private final class Box: @unchecked Sendable {
        var opened = 0
        var pressed = 0
        var traced: [String] = []
    }

    /// Verbatim from `tmux capture-pane` on pane %140, 27 Aug 16:17Z.
    private let codexUpdateScreen = """
      ✨ Update available! 0.149.0 -> 0.150.0
      Release notes: https://github.com/openai/codex/releases/latest

    › 1. Update now (runs `sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'`)
      2. Skip
      3. Skip until next version

      Press enter to continue
    """

    func testTheCodexUpdatePromptReadsAsStoppedNotStarted() {
        let spec = CodexAdapter().trustPrompt!
        guard case .stopped(let screen) = SessionLauncher.classifyPaneScreen(
            codexUpdateScreen, spec: spec) else {
            return XCTFail("the update prompt must not read as a started agent")
        }
        // And the reason travels WITH the verdict — the whole point.
        XCTAssertTrue(screen.contains("Update available"), screen)
        XCTAssertTrue(screen.contains("Press enter to continue"), screen)
    }

    func testASettledBannerStillReadsAsStarted() {
        let spec = CodexAdapter().trustPrompt!
        XCTAssertEqual(
            SessionLauncher.classifyPaneScreen(
                "  \(spec.settledBannerNeedle)  \n\n  › ", spec: spec),
            .started)
    }

    /// The tail, not the head: a TUI's answer is on its last lines, while its
    /// first lines are the same banner on every launch.
    func testTheTailIsWhatGetsLogged() {
        let tail = TrustPromptWatcher.meaningfulTail(codexUpdateScreen)
        XCTAssertTrue(tail.hasSuffix("Press enter to continue"), tail)
        XCTAssertFalse(tail.contains("\n"), "a log line, so one line")
        XCTAssertLessThanOrEqual(tail.count, 401)
    }

    func testABoundedTailNeverFloodsTheLog() {
        let flood = (0..<400).map { "line \($0) padded out to some width" }.joined(separator: "\n")
        XCTAssertLessThanOrEqual(TrustPromptWatcher.meaningfulTail(flood).count, 401)
    }

    /// The regression that matters: giving up is a needs-a-human exit.
    ///
    /// Before 27 Aug this loop had four exits and only one of them opened a
    /// window. The screen nobody had a needle for got neither the "never press
    /// it" promise nor the "let someone see it" one, because a needle list can
    /// only speak about prompts somebody already knew to name.
    func testGivingUpOpensAWindowAndSaysWhatItSaw() {
        let box = Box()
        TrustPromptWatcher.watch(
            spec: CodexAdapter().trustPrompt!,
            read: { self.codexUpdateScreen },
            press: { _ in box.pressed += 1 },
            trace: { box.traced.append($0) },
            label: "tb-test",
            pollInterval: 0.001, maxPolls: 3,
            onNeedsHuman: { _ in box.opened += 1 })

        XCTAssertEqual(box.pressed, 0, "an unrecognised screen is never pressed through")
        XCTAssertEqual(box.opened, 1, "an unrecognised screen is shown to a human, exactly once")
        let giveUp = box.traced.last ?? ""
        XCTAssertTrue(giveUp.contains("Update available"),
                      "the give-up line must carry the screen, not just the expectation: \(giveUp)")
    }

    /// A healthy launch stays a background act — no window, no noise.
    func testAStartedPaneIsLeftAlone() {
        let spec = CodexAdapter().trustPrompt!
        let box = Box()
        TrustPromptWatcher.watch(
            spec: spec,
            read: { "\(spec.settledBannerNeedle)\n› " },
            press: { _ in },
            label: "tb-test",
            pollInterval: 0.001, maxPolls: 6,
            onNeedsHuman: { _ in box.opened += 1 })
        XCTAssertEqual(box.opened, 0, "starting an agent that works is still a background act")
    }
}
