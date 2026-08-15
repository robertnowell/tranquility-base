import XCTest
@testable import TranquilityCore

/// What the 14 Aug airplane failure taught the chain: an offline machine
/// fails a cloud rung once — not through a backoff ladder — and the floor
/// must actually be reached with time to spare. (The floor's own short-clip
/// bug from that incident is pinned by an e2e probe, not here: the loop
/// entry needs a real recogniser.)
final class OfflineRecoveryTests: XCTestCase {

    func testCertainlyOfflineTransportErrorsClassifyAsOffline() {
        for code in [URLError.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed] {
            XCTAssertEqual(TranscriptionFailure.fromTransport(URLError(code)), .offline,
                           "\(code) means no route exists; retrying is pure wait")
        }
    }

    func testAmbiguousTransportErrorsStayRetryable() {
        // A timeout or a mid-flight connection loss can be transient — the
        // TLS abort observed on 13 Aug was, and its retry was the fix.
        for code in [URLError.timedOut, .networkConnectionLost, .cannotConnectToHost] {
            guard case .providerUnavailable = TranscriptionFailure.fromTransport(URLError(code))
            else { return XCTFail("\(code) must stay retryable") }
        }
    }

    private final class CountingOffline: RecoveryTranscriptionProvider, @unchecked Sendable {
        let name = "counting-offline"
        let isConfigured = true
        var calls = 0
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            calls += 1
            throw TranscriptionFailure.offline
        }
    }

    func testOfflineFailsARungOnceWithNoBackoff() async {
        let rung = CountingOffline()
        let chain = RecoveryChain(providers: [rung], maxAttemptsPerProvider: 2,
                                  backoff: [30, 60, 120])
        let started = Date()
        let outcome = await chain.transcribe(
            fileAt: URL(fileURLWithPath: "/tmp/does-not-matter.wav"))
        XCTAssertEqual(rung.calls, 1, "offline is not retried")
        XCTAssertFalse(outcome.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "no backoff sleep was taken — the floor gets its turn now")
    }
}
