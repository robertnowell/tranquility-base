import XCTest
@testable import TranquilityCore

/// Granting Codex's hook trust, once, on the user's instruction.
///
/// The menu is the only route: no CLI flag persists the grant, the
/// `trusted_hash` is an internal canonicalisation this repo could not
/// reproduce, and the app-server is ruled out. So the decision worth testing
/// is not "can we press a key" but "do we press the RIGHT key, and do we
/// believe the config rather than the keystroke".
final class CodexHookApprovalTests: XCTestCase {

    private let menu = """
      Hooks need review
      5 hooks are new or changed.
      Hooks can run outside the sandbox after you trust them.
    › 1. Review hooks
      2. Trust all and continue
      3. Continue without trusting (hooks won't run)
      Press enter to confirm or esc to go back
    """

    // MARK: - Reading the menu

    func testTheTrustRowIsFoundByItsWordsNotItsPosition() {
        XCTAssertEqual(CodexHookApproval.trustAllOption(onScreen: menu), "2")
    }

    /// The failure this guards: a row inserted above shifts the numbering, and
    /// a hardcoded "2" would then choose "Review hooks" instead. Wrong menu
    /// answer, chosen by us, about security.
    func testAReorderedMenuStillFindsTheRightRow() {
        let reordered = """
          Hooks need review
        › 1. Review hooks
          2. Show me what changed
          3. Trust all and continue
          4. Continue without trusting
        """
        XCTAssertEqual(CodexHookApproval.trustAllOption(onScreen: reordered), "3")
    }

    func testNoTrustRowMeansNoKeypress() {
        XCTAssertNil(CodexHookApproval.trustAllOption(
            onScreen: "Hooks need review\n  1. Review hooks\n  2. Continue without trusting"))
    }

    func testTheReviewPromptIsRecognised() {
        XCTAssertTrue(CodexHookApproval.isReviewPrompt(menu))
        XCTAssertFalse(CodexHookApproval.isReviewPrompt("› Ask Codex to do anything"))
    }

    // MARK: - The grant

    func testAlreadyGrantedPressesNothing() {
        var pressed: [String] = []
        let outcome = CodexHookApproval.grant(
            read: { XCTFail("must not read the screen"); return nil },
            press: { pressed.append($0) },
            granted: { true }, wait: { _ in })
        XCTAssertEqual(outcome, .alreadyGranted)
        XCTAssertTrue(pressed.isEmpty)
    }

    func testTheMenuIsAnsweredAndTheConfigIsBelieved() {
        var pressed: [String] = []
        var recorded = false
        let outcome = CodexHookApproval.grant(
            read: { self.menu },
            press: { pressed.append($0); if $0 == "\r" { recorded = true } },
            granted: { recorded }, wait: { _ in })
        XCTAssertEqual(outcome, .granted)
        XCTAssertEqual(pressed, ["2", "\r"])
    }

    /// The menu is answered exactly once even though the screen keeps showing
    /// it for a poll or two afterwards.
    func testTheMenuIsAnsweredOnlyOnce() {
        var pressed: [String] = []
        var polls = 0
        let outcome = CodexHookApproval.grant(
            read: { polls += 1; return self.menu },
            press: { pressed.append($0) },
            granted: { polls > 4 }, wait: { _ in })
        XCTAssertEqual(outcome, .granted)
        XCTAssertEqual(pressed, ["2", "\r"], "pressed the menu more than once")
    }

    /// Answering is not the same as it having taken. A keystroke that lands on
    /// a menu which then closes without writing the record must not be
    /// reported as success: the whole point of this feature is that "installed"
    /// and "running" were allowed to look alike once already.
    func testAnsweredButNotRecordedIsNotSuccess() {
        let outcome = CodexHookApproval.grant(
            read: { self.menu }, press: { _ in },
            granted: { false }, wait: { _ in }, maxPolls: 3)
        XCTAssertEqual(outcome, .notRecorded)
    }

    /// Distinct from the above: we were never asked at all.
    func testTheMenuNeverAppearing() {
        let outcome = CodexHookApproval.grant(
            read: { "› Ask Codex to do anything" }, press: { _ in },
            granted: { false }, wait: { _ in }, maxPolls: 3)
        XCTAssertEqual(outcome, .promptNeverAppeared)
    }

    /// The flag that makes TB-launched sessions work before the grant exists
    /// is the same flag that stops Codex ever asking. Driving the menu with it
    /// still on opens a Codex that never prompts, which this code would then
    /// report as `promptNeverAppeared` forever, correctly and uselessly.
    func testTheSuppressingFlagIsStrippedBeforeDriving() {
        XCTAssertEqual(
            CodexHookApproval.commandThatWillAsk(
                "codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"),
            "codex --dangerously-bypass-approvals-and-sandbox")
    }

    func testACommandWithoutTheFlagIsUnchanged() {
        let plain = "codex --dangerously-bypass-approvals-and-sandbox"
        XCTAssertEqual(CodexHookApproval.commandThatWillAsk(plain), plain)
    }

    func testAnUnreadableScreenIsWaitedOutRatherThanFailed() {
        var polls = 0
        let outcome = CodexHookApproval.grant(
            read: { polls += 1; return polls < 3 ? nil : self.menu },
            press: { _ in }, granted: { polls >= 4 }, wait: { _ in })
        XCTAssertEqual(outcome, .granted)
    }
}
