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

    func testQueuedAndProcessingAreTheSameNonAnswer() {
        XCTAssertEqual(AssemblyAIFileRecovery.state(of: ["status": "queued"]), .processing)
        XCTAssertEqual(AssemblyAIFileRecovery.state(of: ["status": "processing"]), .processing)
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

    func testDefaultChainOrderIsWhisperThenAssemblyThenTheFloor() {
        // The 12 Aug lesson encoded as an assertion: three rungs, two vendors
        // of cloud quality before the on-device floor, so no single vendor's
        // outage — and no single rung's blind spot — decides a transcript.
        XCTAssertEqual(RecoveryChain().providers.map(\.name),
                       ["openai", "assemblyai-file", "apple-speech"])
    }
}
