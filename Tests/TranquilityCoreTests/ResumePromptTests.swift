import XCTest
@testable import TranquilityCore

/// The resume-depth prompt, answered on a revive.
///
/// Claude Code shows "Resuming the full session will consume ... 1. Resume
/// from summary  2. Resume full session as-is" before a session with history
/// resumes, and locks there until a key is pressed. TB used to escalate it to
/// the human on every path. On a revive it now answers it with Return, which
/// selects the recommended summary option, so an agent brought back after a
/// restart comes up running instead of stuck. Off the revive path, nothing
/// changes: it is still escalated, never pressed.
final class ResumePromptTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        var opened = 0
        var pressed = 0
        var lastSteps = -99
        var traced: [String] = []
    }

    /// The screen, with the banner word "Claude" on it too, so the test also
    /// proves the resume check wins over the settled-banner and never-accept
    /// branches below it.
    private let resumeScreen = """
      Claude Code
      Resuming the full session will consume a substantial portion of your usage limits.
    ❯ 1. Resume from summary (recommended)
      2. Resume full session as-is
    """

    private let trustThenNothing = "Quick safety check: trust this folder\n"
        + "❯ 1. Yes, I trust this folder\n  2. No, exit"

    func testARevivePressesTheResumePromptWithSummary() {
        let box = Box()
        TrustPromptWatcher.watch(
            spec: ClaudeCodeAdapter().trustPrompt!,
            read: { self.resumeScreen },
            press: { steps in box.pressed += 1; box.lastSteps = steps },
            trace: { box.traced.append($0) },
            label: "tb-test",
            pollInterval: 0.001, maxPolls: 4,
            answerResumePrompt: true,
            onNeedsHuman: { _ in box.opened += 1 })
        XCTAssertEqual(box.pressed, 1, "a revive answers the resume prompt exactly once")
        XCTAssertEqual(box.lastSteps, 0, "Return where it stands picks the recommended summary")
        XCTAssertEqual(box.opened, 0, "answering it means not escalating it")
        XCTAssertTrue((box.traced.last ?? "").lowercased().contains("resume prompt"),
                      box.traced.last ?? "")
    }

    func testOffTheRevivePathTheResumePromptIsEscalatedNeverPressed() {
        let box = Box()
        TrustPromptWatcher.watch(
            spec: ClaudeCodeAdapter().trustPrompt!,
            read: { self.resumeScreen },
            press: { steps in box.pressed += 1; box.lastSteps = steps },
            trace: { box.traced.append($0) },
            label: "tb-test",
            pollInterval: 0.001, maxPolls: 4,
            answerResumePrompt: false,
            onNeedsHuman: { _ in box.opened += 1 })
        XCTAssertEqual(box.pressed, 0, "off the revive path the resume prompt is never pressed")
        XCTAssertEqual(box.opened, 1, "off the revive path it is escalated to the human, as before")
    }

    func testARevivePastTheTrustPromptStillAnswersTheResumePrompt() {
        let box = Box()
        var reads = 0
        TrustPromptWatcher.watch(
            spec: ClaudeCodeAdapter().trustPrompt!,
            read: { reads += 1; return reads <= 1 ? self.trustThenNothing : self.resumeScreen },
            press: { steps in box.pressed += 1; box.lastSteps = steps },
            trace: { box.traced.append($0) },
            label: "tb-test",
            pollInterval: 0.001, maxPolls: 6,
            answerResumePrompt: true,
            onNeedsHuman: { _ in box.opened += 1 })
        XCTAssertEqual(box.pressed, 2, "one press accepts trust, a second answers the resume prompt")
        XCTAssertEqual(box.opened, 0, "the resume prompt after trust is answered, not escalated")
    }

    /// The safety property: a running agent (no resume prompt on screen) is
    /// never pressed, even on the revive path.
    func testARunningAgentOnTheRevivePathIsNeverPressed() {
        let spec = ClaudeCodeAdapter().trustPrompt!
        let box = Box()
        TrustPromptWatcher.watch(
            spec: spec,
            read: { "\(spec.settledBannerNeedle)\n❯ " },
            press: { steps in box.pressed += 1; box.lastSteps = steps },
            label: "tb-test",
            pollInterval: 0.001, maxPolls: 6,
            answerResumePrompt: true,
            onNeedsHuman: { _ in box.opened += 1 })
        XCTAssertEqual(box.pressed, 0, "no resume prompt on screen means no keypress")
        XCTAssertEqual(box.opened, 0)
    }
}
