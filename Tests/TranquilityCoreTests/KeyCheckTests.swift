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

    /// Every provider-backed key is checked against a CONFIGURED provider.
    /// Without this the two keys added on 13 Sep would produce nil on any
    /// machine with no address for them, and this loop would report full
    /// coverage while asserting nothing about either.
    private let configured: (String) -> URL? = { _ in URL(string: "https://provider.example.test") }

    func testEveryProviderHasAReadOnlyRequest() {
        for key in Secrets.Key.allCases where key.isPasted {
            // Only pasted keys have a provider to ask. This Mac's own device
            // key has nobody to verify it with: the only thing that can say it
            // works is a signature the Gateway accepts, and a "checked,
            // working" row here would be a claim nobody made.
            let request = KeyCheck.request(for: key, value: "probe", providerBase: configured)
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
            KeyCheck.request(for: key, value: "probe", providerBase: configured)?
                .value(forHTTPHeaderField: field)
        }
        XCTAssertEqual(header(.anthropicAPIKey, "x-api-key"), "probe")
        XCTAssertEqual(header(.anthropicAPIKey, "anthropic-version"), "2023-06-01")
        XCTAssertEqual(header(.elevenLabsAPIKey, "xi-api-key"), "probe")
        // Raw, no "Bearer" -- AssemblyAIFileRecovery says so in its own comment.
        XCTAssertEqual(header(.assemblyAIAPIKey, "Authorization"), "probe")
        XCTAssertEqual(header(.openAIAPIKey, "Authorization"), "Bearer probe")
        XCTAssertEqual(header(.crobotAPIKey, "Authorization"), "Bearer probe")
        // BASIC, with the literal username `opencode`. The gateway's own proxy
        // sets exactly this when it forwards to a sandbox, and sending Bearer
        // would report a correct password as rejected.
        XCTAssertEqual(header(.openCodePassword, "Authorization"),
                       "Basic " + Data("opencode:probe".utf8).base64EncodedString())
    }

    /// An unconfigured provider yields NO request, which `verify` turns into
    /// `.unreachable`. That is the honest verdict: an address nobody has set
    /// says nothing about the credential, and reporting it as `.rejected`
    /// would send somebody to rotate a key that was fine.
    func testAnUnconfiguredProviderIsUnreachableRatherThanRejected() {
        let none: (String) -> URL? = { _ in nil }
        XCTAssertNil(KeyCheck.request(for: .crobotAPIKey, value: "probe", providerBase: none))
        XCTAssertNil(KeyCheck.request(for: .openCodePassword, value: "probe", providerBase: none))
    }

    /// The GATEWAY's identity route, not Jarvis's.
    ///
    /// Measured live 13 Sep 2026: `/api/auth/me` on the gateway sits behind
    /// the same auth middleware, so it refuses a bad key correctly and then
    /// serves a GOOD one the single page app, 200 with HTML. A check reading
    /// "working" off that has proved the credential authenticates and nothing
    /// about whether an identity resolves behind it. `/api/v1/me` passes the
    /// same auth and org-scope chain as `/api/v1/tasks`, which is what the
    /// provider actually calls.
    func testCrobotVerifiesAgainstTheGatewaysOwnIdentityRoute() {
        let url = KeyCheck.request(for: .crobotAPIKey, value: "probe",
                                   providerBase: configured)?.url?.path
        XCTAssertEqual(url, "/api/v1/me")
        XCTAssertNotEqual(url, "/api/auth/me", "that is Jarvis's route, not the gateway's")
    }

    func testTheKeyNeverAppearsInTheURL() {
        for key in Secrets.Key.allCases {
            let url = KeyCheck.request(for: key, value: "SECRETVALUE",
                                       providerBase: configured)?.url?.absoluteString ?? ""
            XCTAssertFalse(url.contains("SECRETVALUE"), "\(key) puts the key in the URL")
        }
    }

    func testTheCheckIsBounded() {
        for key in Secrets.Key.allCases {
            let request = KeyCheck.request(for: key, value: "probe", providerBase: configured)
            // A key a person pastes MUST be checkable, or a wrong one sits
            // under a green lamp until it fails in the away-channel. Absence
            // used to read as an unbounded timeout here, which conflated "no
            // check" with "a check that can hang" and would have let a real
            // credential lose its probe silently.
            if key.isPasted {
                XCTAssertNotNil(request, "\(key) can be pasted but never verified")
            }
            // Whatever exists is bounded: somebody is watching a row while it runs.
            if let timeout = request?.timeoutInterval {
                XCTAssertLessThanOrEqual(timeout, 15, "\(key) check can hang too long")
            }
        }
    }
}
