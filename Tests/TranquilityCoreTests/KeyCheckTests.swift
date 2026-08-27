import Foundation
import XCTest
@testable import TranquilityCore

/// What a saved key is told about itself.
///
/// Every mapping here has a wrong answer that costs somebody real time. Calling
/// a rate limit "invalid" sends them to rotate a working key; calling a refusal
/// "could not check" leaves a dead key in the keychain and the failure surfaces
/// hours later as silence in the away-channel, where nothing connects the
/// symptom to the cause.
///
/// Verified against the live providers 26 Aug: a deliberately invalid key
/// returns 401 from Anthropic, ElevenLabs, AssemblyAI and OpenAI alike, and a
/// real one returns 200 from all four. These tests hold the mapping to that.
final class KeyCheckTests: XCTestCase {

    func testTwoHundredIsWorking() {
        XCTAssertEqual(KeyCheck.classify(status: 200, failed: false), .working)
    }

    func testAnySuccessStatusIsWorking() {
        for status in [200, 201, 204, 299] {
            XCTAssertEqual(KeyCheck.classify(status: status, failed: false), .working,
                           "\(status) should be working")
        }
    }

    /// The one that means "you pasted the wrong thing". Measured: all four
    /// providers answer a bad key with 401.
    func testUnauthorizedIsRejected() {
        XCTAssertEqual(KeyCheck.classify(status: 401, failed: false), .rejected(status: 401))
    }

    /// A key that is valid but not entitled still will not work here, and
    /// "rejected" is the honest word for both.
    func testForbiddenIsRejected() {
        XCTAssertEqual(KeyCheck.classify(status: 403, failed: false), .rejected(status: 403))
    }

    /// Rate limiting says nothing about the key. Reporting it as invalid would
    /// send someone to rotate a perfectly good one.
    func testRateLimitIsNotRejected() {
        let outcome = KeyCheck.classify(status: 429, failed: false)
        XCTAssertEqual(outcome, .unexpected(status: 429))
        XCTAssertFalse(outcome.isBad)
    }

    /// The provider having a bad day is not the user having a bad key.
    func testServerErrorIsNotRejected() {
        for status in [500, 502, 503] {
            let outcome = KeyCheck.classify(status: status, failed: false)
            XCTAssertEqual(outcome, .unexpected(status: status))
            XCTAssertFalse(outcome.isBad, "\(status) must not read as a bad key")
        }
    }

    func testTransportFailureIsUnreachable() {
        XCTAssertEqual(KeyCheck.classify(status: nil, failed: true), .unreachable)
        XCTAssertEqual(KeyCheck.classify(status: 200, failed: true), .unreachable)
    }

    func testNoStatusIsUnreachable() {
        XCTAssertEqual(KeyCheck.classify(status: nil, failed: false), .unreachable)
    }

    /// Only an outright refusal is the user's problem to fix now. Everything
    /// else is saved and worth keeping.
    func testOnlyRejectionCountsAsBad() {
        XCTAssertTrue(KeyCheck.Outcome.rejected(status: 401).isBad)
        XCTAssertFalse(KeyCheck.Outcome.working.isBad)
        XCTAssertFalse(KeyCheck.Outcome.unreachable.isBad)
        XCTAssertFalse(KeyCheck.Outcome.unexpected(status: 500).isBad)
    }

    func testEveryOutcomeSaysSomethingUseful() {
        let outcomes: [KeyCheck.Outcome] = [
            .working, .rejected(status: 401), .unexpected(status: 500), .unreachable]
        for outcome in outcomes {
            XCTAssertFalse(outcome.summary.isEmpty)
            // A row that just says "error" has told the reader nothing they can
            // act on, so a status-bearing verdict must carry its number.
            if case .rejected(let status) = outcome {
                XCTAssertTrue(outcome.summary.contains("\(status)"), outcome.summary)
            }
        }
    }

    // MARK: - the requests

    func testEveryProviderHasAReadOnlyRequest() {
        for key in Secrets.Key.allCases {
            let request = KeyCheck.request(for: key, value: "probe")
            XCTAssertNotNil(request, "\(key) has no verification request")
            // Verifying a key must never create, spend, or transcribe anything.
            XCTAssertEqual(request?.httpMethod, "GET", "\(key) is not read-only")
            XCTAssertNil(request?.httpBody)
        }
    }

    /// Each provider wants its key in a different header, and getting one wrong
    /// reports every valid key as rejected.
    func testEachProviderGetsItsOwnHeaderShape() {
        func header(_ key: Secrets.Key, _ field: String) -> String? {
            KeyCheck.request(for: key, value: "probe")?
                .value(forHTTPHeaderField: field)
        }
        XCTAssertEqual(header(.anthropicAPIKey, "x-api-key"), "probe")
        XCTAssertEqual(header(.anthropicAPIKey, "anthropic-version"), "2023-06-01")
        XCTAssertEqual(header(.elevenLabsAPIKey, "xi-api-key"), "probe")
        // Raw, no "Bearer" -- AssemblyAIFileRecovery says so in its own comment.
        XCTAssertEqual(header(.assemblyAIAPIKey, "Authorization"), "probe")
        XCTAssertEqual(header(.openAIAPIKey, "Authorization"), "Bearer probe")
    }

    func testTheKeyNeverAppearsInTheURL() {
        for key in Secrets.Key.allCases {
            let url = KeyCheck.request(for: key, value: "SECRETVALUE")?.url?.absoluteString ?? ""
            XCTAssertFalse(url.contains("SECRETVALUE"), "\(key) puts the key in the URL")
        }
    }

    func testTheCheckIsBounded() {
        for key in Secrets.Key.allCases {
            let timeout = KeyCheck.request(for: key, value: "probe")?.timeoutInterval ?? .infinity
            // Somebody is watching a row while this runs.
            XCTAssertLessThanOrEqual(timeout, 15, "\(key) check can hang too long")
        }
    }
}
