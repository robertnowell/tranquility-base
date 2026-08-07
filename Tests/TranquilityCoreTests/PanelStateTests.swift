import XCTest
@testable import TranquilityCore

/// The transition table, pinned.
///
/// These tests exist because the table had no home that could hold a test. It
/// lived in the executable target, which the test target cannot import, so when
/// the capture states were given stage ownership there was nowhere to record the
/// invariant — and the next person reading `admits()` had only a comment to go on.
/// Moving it to Core is what makes the rules assertable rather than described.
///
/// Every case below is a rule someone paid for once. Deleting one should require
/// deciding that the incident behind it can happen again.
final class PanelStateTests: XCTestCase {

    private let anEvent = "e1"

    // MARK: - What actually protects a live announcement

    /// The load-bearing guard, and NOT the one an incident report blamed.
    ///
    /// A diagnosis attributed a stomped announcement to the five-second ambient
    /// repaint, on the strength of a log line reading "speaking -> idle (idle
    /// repaint)". The ambient path cannot reach a card at all: its caller checks
    /// `allowsAmbientSurface` first, and that is false for every state except
    /// `.hidden` and `.idle`. The log string was shared by all twenty-five callers
    /// and so said nothing about provenance.
    ///
    /// This is the invariant the ambient tick actually rides on. If it ever goes
    /// true for a card state, the ambient repaint really can stomp playback.
    func testAmbientSurfaceIsRefusedByEveryStateThatOwnsTheScreen() {
        let mustRefuseAmbient: [PanelState] = [
            .preparing,
            .speaking(eventId: anEvent),
            .arming,
            .listening(eventId: anEvent),
            .transcribing(startedAt: Date()),
            .pendingSend(utteranceId: "u1"),
            .result,
            .receipt,
            .settings,
        ]
        for state in mustRefuseAmbient {
            XCTAssertFalse(state.allowsAmbientSurface,
                           "\(state.name) must not admit an ambient surface")
        }
        XCTAssertTrue(PanelState.hidden.allowsAmbientSurface)
        XCTAssertTrue(PanelState.idle(waiting: 0).allowsAmbientSurface)
    }

    // MARK: - Capture states own the stage

    /// The incident this encodes: a gesture opened the microphone, the gesture's
    /// own `speech.stop()` woke the interrupted announce task, and its repaint
    /// painted "Ready" over a live microphone — after which every reply gesture
    /// silently refused, because the recorder was never stopped.
    func testCaptureStatesRefuseAStaleRepaint() {
        let capture: [PanelState] = [
            .arming,
            .listening(eventId: anEvent),
            .transcribing(startedAt: Date()),
            .pendingSend(utteranceId: "u1"),
        ]
        for state in capture {
            XCTAssertFalse(state.admits(.idle(waiting: 0)),
                           "\(state.name) must refuse an idle repaint")
            XCTAssertFalse(state.admits(.preparing),
                           "\(state.name) must refuse a new announcement preparing")
            XCTAssertTrue(state.ownsStage, "\(state.name) must own the stage")
        }
    }

    /// The arm window upgrades to the live pill and accepts nothing else. Its
    /// abort path deliberately does not travel this table — `revertArming`
    /// restores the stashed face through the restore door.
    func testArmingOnlyUpgradesToListening() {
        XCTAssertTrue(PanelState.arming.admits(.listening(eventId: anEvent)))
        for next: PanelState in [.idle(waiting: 0), .preparing, .speaking(eventId: anEvent),
                                 .result, .receipt, .settings, .hidden] {
            XCTAssertFalse(PanelState.arming.admits(next),
                           "arming must refuse \(next.name)")
        }
    }

    // MARK: - Replying during playback is the normal case

    /// Not an edge case: `Recorder.start` calls it "the normal case", and the
    /// whole reply flow depends on it staying legal.
    func testAnAnnouncementAdmitsTheReplyFlow() {
        let speaking = PanelState.speaking(eventId: anEvent)
        XCTAssertTrue(speaking.admits(.arming))
        XCTAssertTrue(speaking.admits(.listening(eventId: anEvent)))
        XCTAssertTrue(speaking.canStartReply)
    }

    /// A reply can only start from something that has told you what you are
    /// answering. Recording with nothing to answer spends a transcription to
    /// discover it had nowhere to go.
    func testReplyCannotStartWithoutSomethingToAnswer() {
        for state: PanelState in [.hidden, .idle(waiting: 0), .preparing, .arming,
                                  .listening(eventId: anEvent),
                                  .transcribing(startedAt: Date()), .settings] {
            XCTAssertFalse(state.canStartReply, "\(state.name) has nothing to answer")
        }
        for state: PanelState in [.speaking(eventId: anEvent), .pendingSend(utteranceId: "u"),
                                  .result, .receipt] {
            XCTAssertTrue(state.canStartReply, "\(state.name) is answerable")
        }
    }

    // MARK: - The two stage concepts stay disjoint

    /// A card on stage and a capture owning the stage are different claims, and
    /// nothing may be both: one means "you are being told something", the other
    /// means "you are saying something".
    func testCardOnStageAndOwnsStageNeverOverlap() {
        let all: [PanelState] = [
            .hidden, .idle(waiting: 0), .preparing, .speaking(eventId: anEvent), .arming,
            .listening(eventId: anEvent), .transcribing(startedAt: Date()),
            .pendingSend(utteranceId: "u1"), .result, .receipt, .settings,
        ]
        for state in all {
            XCTAssertFalse(state.isCardOnStage && state.ownsStage,
                           "\(state.name) cannot be both a card and a capture")
        }
    }

    /// Escape means "stop what is happening here", and it is live everywhere but
    /// a hidden panel — including listening and settings, the two states where it
    /// silently did nothing.
    func testEscapeIsLiveWhereverSomethingIsHappening() {
        XCTAssertFalse(PanelState.hidden.acceptsEscape)
        for state: PanelState in [.idle(waiting: 0), .preparing, .speaking(eventId: anEvent),
                                  .arming, .listening(eventId: anEvent),
                                  .transcribing(startedAt: Date()),
                                  .pendingSend(utteranceId: "u1"), .result, .receipt,
                                  .settings] {
            XCTAssertTrue(state.acceptsEscape, "\(state.name) must accept Escape")
        }
    }
}
