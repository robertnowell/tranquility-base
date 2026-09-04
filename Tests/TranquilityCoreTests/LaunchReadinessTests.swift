import Foundation
import XCTest
@testable import TranquilityCore

/// Why a launch may never decide "started" by reading the screen, and what
/// gets written instead of pressing at one.
///
/// Every screen below was captured live on 3 Sep 2026 against claude 2.1.260,
/// in tmux panes shaped the way `launchTmux` makes them. They are the five
/// states a Claude Code pane can sit in before it registers, and the point of
/// this file is that a needle cannot tell them apart from a working session.
final class LaunchReadinessTests: XCTestCase {

    // MARK: - The captured screens

    /// First run, before anything else. Note the syntax sample.
    static let themePicker = """
         Let's get started.

         Choose the text style that looks best with your terminal
         To change this later, run /theme

           1. Auto (match terminal)
         ❯ 2. Dark mode ✔
           3. Light mode

          1  function greet() {
          2 -  console.log("Hello, World!");
          2 +  console.log("Hello, Claude!");
          3  }
         Syntax theme: Monokai Extended (ctrl+t to disable)
        """

    static let signIn = """
         Welcome to Claude Code v2.1.260

         Claude Code can be used with your Claude subscription or billed based
         on API usage through your Console account.
         Select login method:
         ❯ 1. Claude account with subscription · Pro, Max, Team, or Enterprise
           2. Anthropic Console account · API usage billing
           3. 3rd-party platform · Amazon Bedrock, Microsoft Foundry, or Vertex AI
        """

    static let trustDialog = """
         Accessing workspace:

         /Users/someone/a-project

         Quick safety check: Is this a project you created or one you trust?

         Claude Code'll be able to read, edit, and execute files here.

         Security guide

         ❯ No, exit
           Yes, I trust this folder

         Enter to confirm · Esc to cancel
        """

    /// The one that cost the 3 Sep afternoon. It appears AFTER the trust
    /// dialog is cleared, which is why nobody had ever seen it: on a machine
    /// where trust was already granted, the launch never reached it, and on a
    /// machine with `skipDangerousModePermissionPrompt` set it never renders.
    static let bypassGate = """
          WARNING: Claude Code running in Bypass Permissions mode

          In Bypass Permissions mode, Claude Code will not ask for your approval
          before running potentially dangerous commands.
          This mode should only be used in a sandboxed container/VM that has
          restricted internet access and can easily be restored if damaged.
          By proceeding, you accept all responsibility for actions taken while
          running in Bypass Permissions mode.

          ❯ No, exit
            Yes, I accept

          Enter to confirm · Esc to cancel
        """

    static let ready = """
         ▐▛███▛█   Claude Code v2.1.260
        ▝▜██████▀  Opus 5 (1M context) with high effort · Claude Max
          ▝▝ ▝▝    ~/a-project

        ❯
          ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
        """

    static let blocked = [
        ("theme picker", themePicker),
        ("sign-in", signIn),
        ("trust dialog", trustDialog),
        ("bypass gate", bypassGate),
    ]

    // MARK: - The defect, encoded so it cannot come back

    /// EVERY blocked screen contains the settled-banner needle, so
    /// `classifyPaneScreen` calls all four of them `.started`.
    ///
    /// This is not a bug in `classifyPaneScreen`; it is a statement about what
    /// a one-word needle can do. `ClaudeCodeAdapter.settledBannerNeedle` is
    /// "Claude", and this harness prints its own name on every screen it can
    /// stop on, including a code sample that happens to say `Hello, Claude!`.
    /// The test exists so that anyone tempted to put a screen check back on
    /// the launch path sees the four screens it would wave through.
    func testEveryBlockedScreenLooksStartedToTheBannerNeedle() {
        guard let spec = ClaudeCodeAdapter().trustPrompt else {
            return XCTFail("Claude Code adapter must carry a trust prompt spec")
        }
        for (label, screen) in Self.blocked {
            XCTAssertEqual(
                SessionLauncher.classifyPaneScreen(screen, spec: spec), .started,
                "\(label) is a BLOCKED screen and the banner needle still calls it started. "
                + "That is why the launch path reads registration instead.")
        }
    }

    /// The trust watcher recognises exactly one of the four, which is the
    /// other half of the same lesson: pressing keys at screens is a bet on a
    /// list that is always incomplete.
    func testTrustWatcherRecognisesOnlyTheTrustDialog() {
        guard let spec = ClaudeCodeAdapter().trustPrompt else {
            return XCTFail("Claude Code adapter must carry a trust prompt spec")
        }
        func recognised(_ s: String) -> Bool {
            spec.promptNeedles.contains { s.contains($0) }
        }
        XCTAssertTrue(recognised(Self.trustDialog))
        XCTAssertFalse(recognised(Self.themePicker))
        XCTAssertFalse(recognised(Self.signIn))
        XCTAssertFalse(recognised(Self.bypassGate),
                       "The bypass gate says 'Yes, I accept', not 'Yes, I trust this folder'. "
                       + "It is invisible to the trust watcher, and that is what blocked the "
                       + "first external user on 3 Sep.")
    }

    /// A live pane and a blocked one are indistinguishable to the needle in
    /// BOTH directions, which is the whole argument: there is no threshold to
    /// tune, because the signal carries no information.
    func testReadyScreenAlsoMatchesTheSameNeedle() {
        guard let spec = ClaudeCodeAdapter().trustPrompt else {
            return XCTFail("Claude Code adapter must carry a trust prompt spec")
        }
        XCTAssertTrue(Self.ready.contains(spec.settledBannerNeedle))
        XCTAssertTrue(Self.bypassGate.contains(spec.settledBannerNeedle))
    }

    /// The selection glyph is shared between menus and the composer, so it
    /// cannot stand in for "ready" either. Recorded because it was proposed
    /// as a replacement needle on 3 Sep and is wrong.
    func testSelectionGlyphIsNotAReadinessSignal() {
        let glyph = "❯"
        XCTAssertTrue(Self.ready.contains(glyph))
        XCTAssertTrue(Self.themePicker.contains(glyph))
        XCTAssertTrue(Self.trustDialog.contains(glyph))
        XCTAssertTrue(Self.bypassGate.contains(glyph))
    }
}
