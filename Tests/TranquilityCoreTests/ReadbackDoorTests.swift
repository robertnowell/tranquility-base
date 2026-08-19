import Foundation
import XCTest
@testable import TranquilityCore

/// The ruling, 18 Aug, in the user's words: "If I hold Option or if I do
/// Option-Option, it should effectively be the same as hitting Don't Send and
/// then doing Option-Option."
///
/// It was not. ⌥⌥ from the read-back opened a new capture and left the undo
/// countdown running underneath it, so four seconds later the words the gesture
/// had just rejected were dispatched — into a live microphone (app.log 18 Aug
/// 22:39:05, `state: listening -> idle (countdown completed)`). The gesture was
/// not the bug: `OptionTapDecision` returned `.startListening`, which is right.
/// The bug was that leaving `.pendingSend` carried no obligation.
///
/// So the obligation is a property of LEAVING, asserted here, and performed by
/// `StatusHUD.releasePendingSend`. The last test is the one that matters most:
/// it ties this table to `admits`, so a future widening of the legal exits
/// cannot silently re-open the hole.
final class ReadbackDoorTests: XCTestCase {

    /// Every state, one of each case, for the exhaustive sweeps below.
    private let allStates: [PanelState] = [
        .hidden, .idle(waiting: 0), .idle(waiting: 3), .preparing,
        .speaking(eventId: nil), .speaking(eventId: "e"), .arming,
        .listening(eventId: nil), .listening(eventId: "e"),
        .transcribing(startedAt: Date(timeIntervalSince1970: 0)),
        .pendingSend(utteranceId: ""), .pendingSend(utteranceId: "u"),
        .result, .receipt, .settings, .pastAgents,
    ]

    // MARK: - The ruling

    func testLeavingTheReadBackAlwaysReleasesTheSend() {
        let readback = PanelState.pendingSend(utteranceId: "u")
        for next in allStates where !next.isPendingSend {
            XCTAssertTrue(
                readback.releasesPendingSend(movingTo: next),
                "leaving the read-back for \(next.name) must cancel the send")
        }
    }

    /// The one exit that must NOT cancel. Nothing performs it today — `admits`
    /// refuses pendingSend -> pendingSend — but if anything ever re-arms a
    /// read-back, cancelling the send it just armed is the one wrong answer.
    func testReArmingAReadBackIsNotLeavingOne() {
        XCTAssertFalse(
            PanelState.pendingSend(utteranceId: "a")
                .releasesPendingSend(movingTo: .pendingSend(utteranceId: "b")))
        XCTAssertFalse(
            PanelState.pendingSend(utteranceId: "a")
                .releasesPendingSend(movingTo: .pendingSend(utteranceId: "a")))
    }

    /// Nowhere else owns a send, so nowhere else may cancel one. A door that
    /// fired from the wrong side would turn an ordinary repaint into a
    /// discarded utterance.
    func testNoOtherStateReleasesASend() {
        for from in allStates where !from.isPendingSend {
            for next in allStates {
                XCTAssertFalse(
                    from.releasesPendingSend(movingTo: next),
                    "\(from.name) -> \(next.name) must not touch a send")
            }
        }
    }

    // MARK: - The two tables, checked against each other

    /// The property that keeps this fixed. `admits` is the list of exits the
    /// read-back legally has; every one of them must release the send. The
    /// original bug was precisely that this held for one of the three and
    /// nobody had a place to notice.
    func testEveryLegalExitFromTheReadBackReleasesTheSend() {
        let readback = PanelState.pendingSend(utteranceId: "u")
        var admitted = 0
        for next in allStates where readback.admits(next) {
            admitted += 1
            XCTAssertTrue(
                readback.releasesPendingSend(movingTo: next),
                "\(next.name) is a legal exit from the read-back and must release the send")
        }
        // A sweep that admitted nothing would pass vacuously and prove nothing.
        XCTAssertGreaterThan(admitted, 0, "the sweep found no legal exits to check")
    }

    /// The exit the gesture actually took on 18 Aug, named on its own so a
    /// regression reads as the incident rather than as a property failure.
    func testANewCaptureIsALegalExitAndReleasesTheSend() {
        let readback = PanelState.pendingSend(utteranceId: "u")
        XCTAssertTrue(readback.admits(.listening(eventId: nil)),
                      "re-recording during the window is the point; it must stay legal")
        XCTAssertTrue(readback.releasesPendingSend(movingTo: .listening(eventId: nil)))
    }
}
