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

    // MARK: - Codex, audited the same way

    /// Codex first run, captured live 3 Sep against codex-cli 0.152.1.
    static let codexSignIn = """
          Welcome to Codex, OpenAI's command-line coding agent
          Sign in with ChatGPT to use Codex as part of your paid plan
          or connect an API key for usage-based billing
        > 1. Sign in with ChatGPT
             Usage included with Plus, Pro, Business, and Enterprise plans
          2. Sign in with Device Code
          3. Provide your own API key
          Press enter to continue
        """

    /// The one TB must never press Return on, because the selected row runs
    /// an installer. Captured live the same day, on this machine, where it
    /// was blocking every fresh Codex pane.
    static let codexUpdateChooser = """
          ✨ Update available! 0.152.1 -> 0.153.2
          Release notes: https://github.com/openai/codex/releases/latest
        › 1. Update now (runs `sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh'`)
          2. Skip
          3. Skip until next version
          Press enter to continue
        """

    /// The contrast with Claude Code, and the reason Codex never had this bug.
    ///
    /// `settledBannerNeedle` for Codex is "Ask Codex to do anything", the
    /// composer's own idle placeholder, so it appears when the session is
    /// READY and on no blocking screen. Claude Code's is the word "Claude",
    /// which appears on all of them. Same field, opposite information content,
    /// and that single choice is the whole difference between a harness whose
    /// blocked launches surface and one whose blocked launches were announced
    /// as successes.
    func testCodexSettledNeedleIsAbsentFromItsBlockingScreens() {
        guard let spec = CodexAdapter().trustPrompt else {
            return XCTFail("Codex adapter must carry a trust prompt spec")
        }
        XCTAssertFalse(Self.codexSignIn.contains(spec.settledBannerNeedle))
        XCTAssertFalse(Self.codexUpdateChooser.contains(spec.settledBannerNeedle))
    }

    /// The installer row is recognised, so it is never pressed. The needle is
    /// the ROW and not the headline, deliberately: a dismissed update still
    /// prints "Update available!" as a passive banner in a perfectly healthy
    /// session, and matching that stood down every good resume (29 Aug).
    func testCodexUpdateChooserIsRefusedRatherThanAnswered() {
        guard let spec = CodexAdapter().trustPrompt else {
            return XCTFail("Codex adapter must carry a trust prompt spec")
        }
        XCTAssertTrue(spec.neverAutoAcceptNeedles.contains {
            Self.codexUpdateChooser.contains($0.needle)
        }, "pressing Return here runs curl | sh")
        XCTAssertFalse(spec.promptNeedles.contains { Self.codexUpdateChooser.contains($0) },
                       "it must never be mistaken for a trust prompt, which IS auto-accepted")
    }

    /// Sign-in is recognised by nothing, which is correct: it is a screen the
    /// app cannot answer and has no business naming. It reaches the human
    /// through the stuck-screen path instead, carrying its own words.
    func testCodexSignInIsRecognisedByNoNeedleAtAll() {
        guard let spec = CodexAdapter().trustPrompt else {
            return XCTFail("Codex adapter must carry a trust prompt spec")
        }
        XCTAssertFalse(spec.promptNeedles.contains { Self.codexSignIn.contains($0) })
        XCTAssertFalse(spec.neverAutoAcceptNeedles.contains { Self.codexSignIn.contains($0.needle) })
        XCTAssertFalse(Self.codexSignIn.contains(spec.settledBannerNeedle))
    }
}
