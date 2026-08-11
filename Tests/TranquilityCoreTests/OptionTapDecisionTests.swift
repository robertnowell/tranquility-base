import Foundation
import XCTest
@testable import TranquilityCore

/// The rule, ruled 10 Aug, in the user's words: "Option, Option allows the user
/// to speak. If the agent is talking, I don't care — stop talking."
///
/// Every test here is a sentence from that ruling. The first one is the whole
/// thing, and it is exhaustive on purpose: whatever else is true, a tap while
/// speaking opens the microphone.
final class OptionTapDecisionTests: XCTestCase {

    // MARK: - The rule

    func testWhileSpeakingATapAlwaysOpensTheMicrophone() {
        // Every combination that can coexist with "speaking and not already
        // recording". None of them may change the answer.
        for isArmed in [false, true] {
            for withinPairWindow in [false, true] {
                XCTAssertEqual(
                    OptionTapDecision.decide(
                        isSpeaking: true, isRecording: false, isArmed: isArmed,
                        withinPairWindow: withinPairWindow, micGranted: true),
                    .startListening,
                    "armed=\(isArmed) paired=\(withinPairWindow): while speaking, ⌥ lets you speak")
            }
        }
    }

    func testTheFirstTapWhileSpeakingDoesNotMerelyArmAPair() {
        // The exact bug: a tap while speaking used to only remember itself, so it
        // took two inside 450ms to be heard. The log of the session that provoked
        // the ruling has two of them a full second apart, each forgotten.
        XCTAssertNotEqual(
            OptionTapDecision.decide(
                isSpeaking: true, isRecording: false, isArmed: false,
                withinPairWindow: false, micGranted: true),
            .armFirstOfPair,
            "a lone tap while speaking must not be swallowed by the pair window")
    }

    // MARK: - Ending a live capture

    func testATapDuringALiveCaptureEndsItAndSends() {
        XCTAssertEqual(
            OptionTapDecision.decide(
                isSpeaking: false, isRecording: true, isArmed: false,
                withinPairWindow: false, micGranted: true),
            .endCapture)
    }

    func testEndingACaptureDoesNotDependOnPermissionState() {
        // The capture already exists; refusing to end it because a permission
        // check reads false would leave a capture with no way out.
        XCTAssertEqual(
            OptionTapDecision.decide(
                isSpeaking: false, isRecording: true, isArmed: false,
                withinPairWindow: false, micGranted: false),
            .endCapture)
    }

    func testATapWhileAKeyIsHeldIsPartOfTheHoldNotAGesture() {
        XCTAssertNotEqual(
            OptionTapDecision.decide(
                isSpeaking: false, isRecording: true, isArmed: true,
                withinPairWindow: false, micGranted: true),
            .endCapture,
            "an armed press is a hold resolving, not a tap ending a capture")
    }

    // MARK: - The ordinary double tap, away from speech

    func testTwoQuickTapsFromIdleOpenTheMicrophone() {
        XCTAssertEqual(
            OptionTapDecision.decide(
                isSpeaking: false, isRecording: false, isArmed: false,
                withinPairWindow: true, micGranted: true),
            .startListening)
    }

    func testOneTapFromIdleWaitsForItsPartner() {
        XCTAssertEqual(
            OptionTapDecision.decide(
                isSpeaking: false, isRecording: false, isArmed: false,
                withinPairWindow: false, micGranted: true),
            .armFirstOfPair)
    }

    // MARK: - Permission

    func testWithoutMicrophonePermissionNothingOpens() {
        for isSpeaking in [false, true] {
            XCTAssertEqual(
                OptionTapDecision.decide(
                    isSpeaking: isSpeaking, isRecording: false, isArmed: false,
                    withinPairWindow: true, micGranted: false),
                .ignore,
                "speaking=\(isSpeaking): we cannot open a microphone we were not given")
        }
    }

    // MARK: - Total

    func testEveryCombinationDecidesSomething() {
        // No input shape may fall through to an implicit default. Sixteen states
        // is small enough to enumerate, and enumerating them is the only way to
        // know the handler cannot be surprised.
        var seen = Set<String>()
        for a in [false, true] { for b in [false, true] {
            for c in [false, true] { for d in [false, true] {
                let decision = OptionTapDecision.decide(
                    isSpeaking: a, isRecording: b, isArmed: c,
                    withinPairWindow: d, micGranted: true)
                seen.insert("\(decision)")
            }}}}
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.contains("startListening"))
        XCTAssertTrue(seen.contains("endCapture"))
        XCTAssertTrue(seen.contains("armFirstOfPair"))
    }

    // MARK: - The twin

    /// The regression the ⌥⌥ fix created, named. First tap opens the mic; the
    /// second half of the same gesture must not close it 300ms later with
    /// nothing said. Observed 10 Aug 00:55:11–12 on session 2dc2b367.
    func testTheSecondTapOfADoubleTapDoesNotCloseWhatTheFirstOpened() {
        XCTAssertEqual(
            OptionTapDecision.decide(
                isSpeaking: false, isRecording: true, isArmed: false,
                withinPairWindow: true, listeningJustStarted: true, micGranted: true),
            .ignore,
            "⌥⌥ must not open the microphone and immediately send silence")
    }

    /// …and the escape hatch still has to work a moment later. Swallowing the
    /// twin must not become swallowing every tap.
    func testATapAfterThePairWindowStillEndsTheCapture() {
        XCTAssertEqual(
            OptionTapDecision.decide(
                isSpeaking: false, isRecording: true, isArmed: false,
                withinPairWindow: false, listeningJustStarted: false, micGranted: true),
            .endCapture,
            "once the gesture is over, a tap sends — that is the whole point of tap-to-send")
    }

}
