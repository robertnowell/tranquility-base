import XCTest
@testable import VoiceDispatchCore

/// The accumulation rules behind the isFinal-truncation fix (PR #1 harvest).
///
/// `SFSpeechRecognizer` emits one settled result per pause-delimited utterance
/// and marks only the last `isFinal`; the old code kept only that one, so a
/// 22-second paragraph transcribed as its closing clause. These tests pin the
/// pure accumulator the fix rests on — no SFSpeech, no audio fixtures, no
/// permissions — so the rules survive refactors even though the recogniser
/// itself can't run in CI.
final class AppleSpeechAccumulationTests: XCTestCase {

    func testUtterancesJoinInSpokenOrderRegardlessOfArrival() {
        let u = AppleSpeechRecovery.Utterances()
        // Arrival order is recogniser's choice; spoken order is start time.
        u.record(start: 20.43, text: "and that's the whole idea.")
        u.record(start: 0.87, text: "The first nineteen seconds")
        u.record(start: 19.02, text: "matter most,")
        XCTAssertEqual(u.joined(),
                       "The first nineteen seconds matter most, and that's the whole idea.")
        XCTAssertEqual(u.count, 3)
    }

    func testRefinedReportOfSameUtteranceReplacesNotAppends() {
        // Callbacks for ONE utterance arrive repeatedly as the recogniser
        // refines it. Appending was the first attempt's bug: "…connected To the
        // metric they're working to improve To the metric they're working…"
        let u = AppleSpeechRecovery.Utterances()
        u.record(start: 0.87, text: "The first draft of this utterance")
        u.record(start: 0.87, text: "The final draft of this utterance")
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u.joined(), "The final draft of this utterance")
    }

    func testTimestampJitterCannotDuplicateAnUtterance() {
        // Re-reports carry float jitter; keys are rounded to 10ms so two
        // nearly-equal start times land on one utterance, not two.
        let u = AppleSpeechRecovery.Utterances()
        u.record(start: 5.001, text: "first version")
        u.record(start: 5.004, text: "refined version")
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u.joined(), "refined version")
    }

    func testDistinctUtterancesTenMillisecondsApartSurvive() {
        // The rounding must merge jitter, not neighbours: 10ms apart is the
        // resolution floor and stays two utterances.
        let u = AppleSpeechRecovery.Utterances()
        u.record(start: 5.00, text: "one")
        u.record(start: 5.01, text: "two")
        XCTAssertEqual(u.count, 2)
        XCTAssertEqual(u.joined(), "one two")
    }

    func testEmptyAccumulatorJoinsToEmpty_theNoSpeechPath() {
        // joined().isEmpty is what routes to noSpeechDetected — it must be
        // empty-string empty, not " " from joining zero pieces.
        let u = AppleSpeechRecovery.Utterances()
        XCTAssertEqual(u.joined(), "")
        XCTAssertEqual(u.count, 0)
    }

    func testSingleUtteranceRecordingIsUnchangedByTheFix() {
        // The regression guard for short dictations: one settled utterance in,
        // exactly that text out — within a character of the old behaviour.
        let u = AppleSpeechRecovery.Utterances()
        u.record(start: 0.5, text: "Ship it.")
        XCTAssertEqual(u.joined(), "Ship it.")
    }
}
