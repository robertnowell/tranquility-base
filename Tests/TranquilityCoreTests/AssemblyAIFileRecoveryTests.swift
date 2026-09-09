import XCTest
@testable import TranquilityCore

/// The network-free half of the vendor-diversity rung: poll-state reduction
/// and its place in the default chain. The live path is exercised by
/// `tbase transcribe <wav> --assemblyai-only` against a real recording.
final class AssemblyAIFileRecoveryTests: XCTestCase {

    func testCompletedCarriesItsTrimmedText() {
        XCTAssertEqual(
            AssemblyAIFileRecovery.state(of: ["status": "completed", "text": "  Ship it. \n"]),
            .completed("Ship it."))
    }

    func testErrorCarriesItsReason() {
        XCTAssertEqual(
            AssemblyAIFileRecovery.state(of: ["status": "error", "error": "download failed"]),
            .failed("download failed"))
    }

    func testObservedSilentAudioErrorIsANoSpeechObservation() {
        XCTAssertEqual(AssemblyAIFileRecovery.state(of: ["status": "error",
            "error": "language_detection cannot be performed on files with no spoken audio."]), .noSpeechDetected)
    }

    func testOtherLanguageDetectionFailuresAreNotTreatedAsSilence() {
        let reason = "detected language confidence is below the requested confidence threshold"
        XCTAssertEqual(AssemblyAIFileRecovery.state(of: ["status": "error", "error": reason]), .failed(reason))
    }

    func testQueuedAndProcessingAreTheSameNonAnswer() {
        XCTAssertEqual(AssemblyAIFileRecovery.state(of: ["status": "queued"]), .processing)
        XCTAssertEqual(AssemblyAIFileRecovery.state(of: ["status": "processing"]), .processing)
    }

    func testMalformedCompletionDoesNotDeclareSilence() {
        XCTAssertEqual(AssemblyAIFileRecovery.state(of: ["status": "completed"]),
                       .failed("completed transcript has no text field"))
    }

    func testAnUnknownStatusKeepsPollingRatherThanInventingAnOutcome() {
        // A new server-side status must read as "not terminal yet", never as
        // success or failure — the poll ceiling bounds the wait either way.
        XCTAssertEqual(AssemblyAIFileRecovery.state(of: ["status": "reticulating"]), .processing)
        XCTAssertEqual(AssemblyAIFileRecovery.state(of: [:]), .processing)
    }

    func testUnconfiguredRungReportsItselfHonestly() {
        XCTAssertFalse(AssemblyAIFileRecovery(keyOverride: nil).isConfigured)
        XCTAssertTrue(AssemblyAIFileRecovery(keyOverride: "k").isConfigured)
    }

    func testDefaultChainAssessesFilesBeforeTheGenerativeFallback() {
        // The reported silent captures must get a file assessment from the
        // primary provider before a generative fallback is asked for text.
        XCTAssertEqual(RecoveryChain().providers.map(\.name),
                       ["assemblyai-file", "openai", "apple-speech"])
    }
}
