import XCTest
@testable import TranquilityCore

/// The state that is on this machine permanently and had no name until 19 Aug:
/// a session locked at the resume prompt. Fixtures are the real payload —
/// `status: waiting · waitingFor: dialog open`, read off `0dbd073e` at 20:39
/// while it sat at "1. Resume from summary / 2. Resume full session as-is".
final class WaitingAtTests: XCTestCase {

    func testAProcessThatIsNotWaitingIsNotWaitingAtAnything() {
        XCTAssertNil(WaitingAt.read(status: "idle", waitingFor: nil, resumed: false))
        XCTAssertNil(WaitingAt.read(status: "busy", waitingFor: nil, resumed: true))
        XCTAssertNil(WaitingAt.read(status: nil, waitingFor: "dialog open", resumed: true))
    }

    func testAnOpenDialogOnAProcessThatHasHeardNothingIsTheResumePrompt() {
        XCTAssertEqual(
            WaitingAt.read(status: "waiting", waitingFor: "dialog open", resumed: true),
            .resumePrompt)
    }

    /// The same dialog mid-session is something else — a permission prompt, a
    /// trust prompt — and must not claim to be the resume one.
    func testAnOpenDialogMidSessionIsJustADialog() {
        XCTAssertEqual(
            WaitingAt.read(status: "waiting", waitingFor: "dialog open", resumed: false),
            .dialog)
    }

    func testAnythingElseItIsWaitingForIsAQuestion() {
        XCTAssertEqual(
            WaitingAt.read(status: "waiting", waitingFor: "input needed", resumed: false),
            .question)
        XCTAssertEqual(
            WaitingAt.read(status: "waiting", waitingFor: nil, resumed: true),
            .question)
    }

    /// The three read differently on the row, because they need different things
    /// from the reader. A row that said "asking you a question" for all three
    /// would send you looking for a question nobody asked.
    func testTheThreeDoNotReadAlike() {
        let all: [WaitingAt] = [.question, .dialog, .resumePrompt]
        XCTAssertEqual(Set(all.map(\.short)).count, 3)
        XCTAssertEqual(Set(all.map(\.full)).count, 3)
    }

    /// The one that can be answered from the panel is the one that is a question.
    func testOnlyAQuestionTakesATypedReply() {
        XCTAssertTrue(WaitingAt.question.acceptsTypedReply)
        XCTAssertFalse(WaitingAt.dialog.acceptsTypedReply)
        XCTAssertFalse(WaitingAt.resumePrompt.acceptsTypedReply)
    }

    // MARK: - The send path, which reads the same field

    /// The rule was always right and its witness went stale. Being absent from
    /// `claude agents --json` was how a blocked session used to look; the CLI now
    /// registers it and says `waitingFor: dialog open`, and `canDispatch` waved
    /// it through because it read the status and not the reason.
    func testADialogRefusesTypedText() {
        XCTAssertFalse(Readiness.waiting("dialog open").canDispatch)
        XCTAssertTrue(Readiness.waiting("dialog open").isDialog)
    }

    /// And the daily loop is untouched: a question still takes an answer.
    func testAQuestionStillDispatches() {
        XCTAssertTrue(Readiness.waiting("input needed").canDispatch)
        XCTAssertTrue(Readiness.waiting(nil).canDispatch)
        XCTAssertFalse(Readiness.waiting("input needed").isDialog)
    }

    /// The old witness still counts. Absent from the list is still a dialog —
    /// this adds a second way to see one, it does not replace the first.
    func testTheOldWitnessStillHolds() {
        XCTAssertTrue(Readiness.notRegistered.isDialog)
        XCTAssertFalse(Readiness.notRegistered.canDispatch)
    }

    /// Matched exactly, not by substring: this decides whether text is typed at
    /// a menu, and a loose match is how a new value would quietly acquire that
    /// power.
    func testTheMatchIsExact() {
        XCTAssertTrue(Readiness.waiting("dialog open is what it says").canDispatch)
        XCTAssertEqual(Readiness.dialogOpen, "dialog open")
    }
}
