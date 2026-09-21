import XCTest
@testable import TranquilityCore

/// Claude Code's "Allow external CLAUDE.md file imports?" dialog, and the
/// class it belongs to: a dialog the settled-banner word is printed on.
///
/// Measured 21 Sep 2026. A revive of 4094579d landed on this screen; the
/// watcher logged "started with no trust prompt; watcher done" four seconds
/// in, because the screen contains the word "Claude"; registration then
/// failed; the card read "needs you" with no question and no door; and the
/// pane sat on the dialog for forty minutes. The screen below is the pane,
/// verbatim from `tmux capture-pane`.
final class ExternalImportsPromptTests: XCTestCase {

    static let liveScreen = """
      Allow external CLAUDE.md file imports?
      This project's CLAUDE.md imports files outside the current working directory. Never allow this for third-party
      repositories.
      External imports:
        /Users/robertnowell/Projects/voice-controlled-coding-agents/tb-voice/AGENTS.md
      Important: Only use Claude Code with files you trust. Accessing untrusted files may pose security risks
      https://code.claude.com/docs/en/security
      ❯ No, disable external imports
        Yes, allow external imports
      Enter to confirm · Esc to cancel
    """

    private final class Box: @unchecked Sendable {
        var pressed = 0
        var questions: [String] = []
        var traced: [String] = []
    }

    func testTheWatcherEscalatesItAndNeverPresses() {
        let box = Box()
        TrustPromptWatcher.watch(
            spec: ClaudeCodeAdapter().trustPrompt!,
            read: { Self.liveScreen },
            press: { _ in box.pressed += 1 },
            trace: { box.traced.append($0) },
            label: "tb-test",
            pollInterval: 0.001, maxPolls: 6,
            answerResumePrompt: true,
            onNeedsHuman: { box.questions.append($0) })
        XCTAssertEqual(box.pressed, 0, "a security grant is never pressed, revive or not")
        XCTAssertEqual(box.questions.count, 1)
        XCTAssertTrue(box.questions.first?.contains("import") == true, box.questions.first ?? "")
        XCTAssertFalse(box.traced.contains { $0.contains("started with no trust prompt") },
                       "the banner word on a dialog is not a settled banner")
    }

    /// The general case the needle above does not cover: a dialog nobody
    /// has named yet. The footer alone must keep it from reading as started,
    /// so the stuck-screen branch can say what it saw.
    func testAnUnnamedDialogWithTheFooterNeverSettles() {
        let unnamed = """
          Claude Code wants to do something new?
          ❯ No, thanks
            Yes, go ahead
          Enter to confirm · Esc to cancel
        """
        let box = Box()
        TrustPromptWatcher.watch(
            spec: ClaudeCodeAdapter().trustPrompt!,
            read: { unnamed },
            press: { _ in box.pressed += 1 },
            trace: { box.traced.append($0) },
            label: "tb-test",
            pollInterval: 0.001, maxPolls: 6,
            onNeedsHuman: { box.questions.append($0) })
        XCTAssertEqual(box.pressed, 0)
        XCTAssertEqual(box.questions.count, 1, box.traced.joined(separator: "\n"))
        XCTAssertTrue(box.questions.first?.contains("does not recognise") == true)
        XCTAssertTrue(box.questions.first?.contains("Yes, go ahead") == true,
                      "an unnamed screen reaches the reader as its own text")
    }

    /// A running agent still settles: the veto is the footer, not the word.
    func testARunningAgentStillReadsAsStarted() {
        let banner = "  Claude Code v2.1\n  ❯ \n  ? for shortcuts"
        let spec = ClaudeCodeAdapter().trustPrompt!
        XCTAssertEqual(SessionLauncher.classifyPaneScreen(banner, spec: spec), .started)
        if case .stopped = SessionLauncher.classifyPaneScreen(Self.liveScreen, spec: spec) {
        } else {
            XCTFail("the dialog must classify as stopped, whatever words it contains")
        }
    }

    /// Why `paneQuestion` recognises on the whole capture: the headline is
    /// the needle, and the six-line tail the card quotes never carries it.
    func testTheNeedleIsAboveTheTail() {
        let spec = ClaudeCodeAdapter().trustPrompt!
        XCTAssertNotNil(TrustPromptWatcher.recognisedQuestion(on: Self.liveScreen, spec: spec))
        let tail = TrustPromptWatcher.meaningfulTail(Self.liveScreen)
        XCTAssertNil(TrustPromptWatcher.recognisedQuestion(on: tail, spec: spec),
                     "recognising on the tail alone would miss this dialog: \(tail)")
        XCTAssertTrue(tail.contains("Yes, allow external imports"),
                      "the tail still carries the options, which is what it is for")
    }
}
