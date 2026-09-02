import XCTest
@testable import TranquilityCore

/// An update may never land on top of someone talking.
///
/// These assert both directions of every rule, because the failure that matters
/// here is asymmetric and invisible: an update that installs too eagerly eats a
/// reply on somebody else's machine and leaves nothing behind to read, while an
/// update that is too shy merely arrives late. Only one of those is discoverable
/// after the fact, so the eager direction gets the same weight as the shy one.
final class UpdateReadinessTests: XCTestCase {

    // MARK: - The two moments an install is allowed

    func testHiddenAndIdleAllowInstall() {
        XCTAssertNil(UpdateReadiness.block(panel: .hidden, inFlightUtterances: 0))
        XCTAssertNil(UpdateReadiness.block(panel: .idle(waiting: 0), inFlightUtterances: 0))
    }

    /// Waiting sessions belong to the agents, not to us. A relaunch does not
    /// disturb them, so a busy grid is still a fine moment to update.
    func testWaitingSessionsDoNotBlock() {
        XCTAssertNil(UpdateReadiness.block(panel: .idle(waiting: 12), inFlightUtterances: 0))
    }

    // MARK: - The microphone and the words

    func testCapturePathBlocks() {
        for state: PanelState in [
            .arming,
            .listening(eventId: "e1"),
            .transcribing(startedAt: Date()),
            .pendingSend(utteranceId: "u1"),
        ] {
            XCTAssertEqual(
                UpdateReadiness.block(panel: state, inFlightUtterances: 0), .panelEngaged,
                "\(state.name) must hold the install: audio is live or in motion")
        }
    }

    func testSpeakingBlocks() {
        XCTAssertEqual(
            UpdateReadiness.block(panel: .preparing, inFlightUtterances: 0), .panelEngaged)
        XCTAssertEqual(
            UpdateReadiness.block(panel: .speaking(eventId: nil), inFlightUtterances: 0),
            .panelEngaged)
    }

    /// Faces a person is reading. Nothing durable is lost, but the panel would
    /// vanish mid-read, so they hold too.
    func testReadableFacesBlock() {
        for state: PanelState in [.result, .receipt, .settings, .pastAgents] {
            XCTAssertEqual(
                UpdateReadiness.block(panel: state, inFlightUtterances: 0), .panelEngaged,
                "\(state.name) is on screen and being read")
        }
    }

    // MARK: - The queue, which has no face

    /// The case the panel alone cannot see: a reply dispatching to a session with
    /// nothing on screen. This is the one that would have shipped broken if the
    /// predicate had only asked the panel.
    func testInFlightUtterancesBlockWithQuietPanel() {
        XCTAssertEqual(
            UpdateReadiness.block(panel: .hidden, inFlightUtterances: 1),
            .utterancesInFlight)
        XCTAssertEqual(
            UpdateReadiness.block(panel: .idle(waiting: 0), inFlightUtterances: 3),
            .utterancesInFlight)
    }

    /// The panel wins the naming when both are true, because it is the one the
    /// user can see and therefore the one that explains the delay.
    func testPanelReasonReportedWhenBothBlock() {
        XCTAssertEqual(
            UpdateReadiness.block(panel: .listening(eventId: nil), inFlightUtterances: 4),
            .panelEngaged)
    }

    // MARK: - Shape

    /// A poll that is too fast burns a machine left recording for an hour; one
    /// that is too slow leaves a finished session waiting. Pinned so a casual
    /// edit has to argue with a number.
    func testRecheckIntervalIsSaneForAPoll() {
        XCTAssertGreaterThanOrEqual(UpdateReadiness.recheckInterval, 5)
        XCTAssertLessThanOrEqual(UpdateReadiness.recheckInterval, 60)
    }
}
