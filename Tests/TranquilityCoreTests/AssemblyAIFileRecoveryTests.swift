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

    /// The upload is most of this rung's latency, so what goes up must be the
    /// compressed copy -- and when compression is not possible, the original,
    /// because a recovery that refuses to run is worse than a slow one.
    func testUploadsTheCompressedCopyAndFallsBackToTheOriginal() async throws {
        final class Capture: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var uploaded: Data?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                if request.url?.path.hasSuffix("/upload") == true {
                    Capture.uploaded = request.httpBodyStream.map { stream in
                        stream.open(); defer { stream.close() }
                        var data = Data(); var buffer = [UInt8](repeating: 0, count: 8 << 10)
                        while case let read = stream.read(&buffer, maxLength: buffer.count), read > 0 {
                            data.append(contentsOf: buffer[0..<read])
                        }
                        return data
                    } ?? request.httpBody
                }
                // One reply that satisfies all three stages: upload, create and a
                // poll that is already terminal, so the rung returns at once.
                let body = Data(#"{"upload_url":"https://example.invalid/a","id":"x","status":"completed","text":"ok"}"#.utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                               httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Capture.self]

        let original = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-test-\(UUID().uuidString).wav")
        try Data(repeating: 0xAB, count: 40_000).write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        let smaller = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-test-\(UUID().uuidString).m4a")
        try Data(repeating: 0xCD, count: 5_000).write(to: smaller)

        var rung = AssemblyAIFileRecovery(keyOverride: "k")
        rung.session = URLSession(configuration: configuration)
        rung.pollingInterval = 0.01
        rung.compress = { _ in smaller }
        Capture.uploaded = nil
        _ = try? await rung.transcribe(fileAt: original)
        XCTAssertEqual(Capture.uploaded?.count, 5_000, "the compressed copy is what should be uploaded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: smaller.path),
                       "the compressed copy is a temp file and must not be left behind")

        // Compression unavailable: the original still goes, unchanged.
        var plain = AssemblyAIFileRecovery(keyOverride: "k")
        plain.session = URLSession(configuration: configuration)
        plain.pollingInterval = 0.01
        plain.compress = { _ in nil }
        Capture.uploaded = nil
        _ = try? await plain.transcribe(fileAt: original)
        XCTAssertEqual(Capture.uploaded?.count, 40_000, "with no compression, send the recording as it is")
    }

    func testDefaultChainAssessesFilesBeforeTheGenerativeFallback() {
        // The reported silent captures must get a file assessment from the
        // primary provider before a generative fallback is asked for text.
        XCTAssertEqual(RecoveryChain().providers.map(\.name),
                       ["assemblyai-file", "openai", "apple-speech"])
    }
}
