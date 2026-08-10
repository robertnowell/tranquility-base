import AVFoundation
import Speech
import XCTest
@testable import TranquilityCore

/// The interrupt gate's order, and the one veto the panel explains.
///
/// The room-listening detector these tests were originally written around was
/// deleted on 10 Aug (see docs/ruling-the-courtesy-check-is-one-question.md).
/// What survives is the part that earned its keep: the gate asks the cheap
/// questions in a fixed order, and audio-in-use is the only veto a user is told
/// about, because it is the only one that looks like "the agent never came
/// back" from the outside.
final class CourtesyGateTests: XCTestCase {

    private func gate(locked: Bool = false, front: String? = nil,
                      audioBusy: String? = nil, idle: Double = 1000) -> InterruptGate {
        InterruptGate(minimumIdleSeconds: 8, signals: .init(
            idleSeconds: { idle }, frontmostApp: { front },
            screenLocked: { locked }, audioBusyWith: { audioBusy }))
    }

    /// Scenario 5 — the case that ships broken today. Zoom is NOT frontmost, so
    /// `mutedApps` matches nothing; the device signal catches it anyway.
    func testBackgroundCallIsVetoedEvenThoughTheMutedListMissesIt() {
        let decision = gate(front: "Terminal", audioBusy: "zoom.us").evaluate()
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reason, "audio in use by zoom.us")
        XCTAssertTrue(decision.heldForCourtesy, "this is the veto the panel explains")
    }
    /// Scenario 9 / the ordering rule: a locked screen is answered before the
    /// microphone is ever consulted. Asserted by making the mic signal fail the
    /// test if it is reached — the drill-in-a-unit-test for "the recording light
    /// must never come on over a lock screen".
    func testLockedScreenIsAnsweredBeforeTheMicrophoneIsConsulted() {
        let gate = InterruptGate(minimumIdleSeconds: 8, signals: .init(
            idleSeconds: { 1000 }, frontmostApp: { nil }, screenLocked: { true },
            audioBusyWith: {
                XCTFail("audio must not be consulted once a cheaper veto fired")
                return nil
            }))
        XCTAssertFalse(gate.evaluate().allowed)
        XCTAssertEqual(gate.evaluate().reason, "screen is locked")
    }
    func testFrontmostMutedAppIsAnsweredBeforeTheMicrophone() {
        let gate = InterruptGate(minimumIdleSeconds: 8, signals: .init(
            idleSeconds: { 1000 }, frontmostApp: { "zoom.us" }, screenLocked: { false },
            audioBusyWith: {
                XCTFail("audio must not be consulted once a cheaper veto fired")
                return nil
            }))
        XCTAssertEqual(gate.evaluate().reason, "muted app in front: zoom.us")
    }
    /// A call in progress outranks a recent keystroke: the mic veto is checked
    /// before idle time, so the reason a user reads is the true one.
    func testMicrophoneOutranksIdleTime() {
        let decision = gate(audioBusy: "zoom.us", idle: 0).evaluate()
        XCTAssertEqual(decision.reason, "audio in use by zoom.us")
    }
    func testQuiescentSignalsAllowSpeech() {
        let gate = InterruptGate(minimumIdleSeconds: 0, signals: .quiescent)
        let decision = gate.evaluate()
        XCTAssertTrue(decision.allowed)
        XCTAssertFalse(decision.heldForCourtesy)
    }
    /// Every other veto leaves `heldForCourtesy` false — only the microphone
    /// earns the explanation, because only it looks like "the agent never came
    /// back" from the outside.
    func testOnlyTheMicrophoneVetoIsExplainedToTheUser() {
        XCTAssertFalse(gate(locked: true).evaluate().heldForCourtesy)
        XCTAssertFalse(gate(front: "zoom.us").evaluate().heldForCourtesy)
        XCTAssertFalse(gate(idle: 0).evaluate().heldForCourtesy)
    }

    /// The finding that reshaped this whole feature, pinned. Siri and the Sound
    /// settings pane hold the microphone continuously on an idle machine, so a
    /// device-level "is the mic in use" gate would veto every announcement for
    /// as long as System Settings is open — silence with no visible cause, which
    /// is worse than the interruption it prevents.
    func testAlwaysOnSystemClientsDoNotHoldTheHail() {
        for client in ["com.apple.CoreSpeech", "com.apple.Sound-Settings.extension"] {
            XCTAssertTrue(AudioInputDevice.alwaysOnAudioClients.contains(client),
                          "\(client) must not be able to silence the app")
        }
    }

    /// And our own TTS must not silence us: an app that refused to announce
    /// because it was announcing would deadlock on the first hail.
    func testOurOwnAudioDoesNotHoldTheHail() {
        let ours = "com.robertnowell.voice-dispatch"
        XCTAssertNil(AudioInputDevice.otherAppUsingAudio(ourBundleID: ours).flatMap {
            $0 == ours ? $0 : nil
        }, "our own bundle id must never be reported as the blocker")
    }
}
