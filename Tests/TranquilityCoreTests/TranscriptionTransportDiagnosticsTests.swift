import XCTest
@testable import TranquilityCore

final class TranscriptionTransportDiagnosticsTests: XCTestCase {
    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var failingStage = "/v2/transcript"
        nonisolated(unsafe) static var status = 400
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url!.path
            let failed = path == Self.failingStage
            let body = path == "/v2/upload" ? #"{"upload_url":"https://fixture.invalid/audio"}"#
                : path == "/v2/transcript" ? #"{"id":"00000000-0000-0000-0000-000000000001"}"#
                : #"{"status":"completed","text":""}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: failed ? Self.status : 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func transcribe(failingStage: String, status: Int) async throws -> TranscriptionResult {
        Stub.failingStage = failingStage; Stub.status = status
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        var provider = AssemblyAIFileRecovery(keyOverride: "fixture-key")
        provider.session = URLSession(configuration: config)
        provider.pollingInterval = 0
        defer { provider.session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(count: 32000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await provider.transcribe(fileAt: file)
    }

    func testRejectedCreateIsAStatusCodeNotAnEmptyTranscript() async {
        do { _ = try await transcribe(failingStage: "/v2/transcript", status: 400); XCTFail("expected HTTP error") }
        catch { XCTAssertEqual(error as? TranscriptionFailure, .providerHTTP(status: 400, stage: "create")) }
    }

    func testUnauthorizedPollStopsImmediatelyInsteadOfPollingForTenMinutes() async {
        let start = Date()
        do {
            _ = try await transcribe(failingStage: "/v2/transcript/00000000-0000-0000-0000-000000000001", status: 401)
            XCTFail("expected authentication error")
        } catch { XCTAssertEqual(error as? TranscriptionFailure, .authenticationFailed) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCompletedEmptyTranscriptMeansProviderDetectedNoSpeech() async {
        do { _ = try await transcribe(failingStage: "/never", status: 400); XCTFail("expected no-speech observation") }
        catch { XCTAssertEqual(error as? TranscriptionFailure, .noSpeechDetected) }
    }
}
