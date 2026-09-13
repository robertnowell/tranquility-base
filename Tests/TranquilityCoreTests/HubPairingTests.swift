import CryptoKit
import XCTest
@testable import TranquilityCore

/// Connecting a Mac: the code is this machine's own, the phrase is what makes
/// the browser's question answerable, and a token arrives exactly once and
/// only after somebody said yes. No socket is opened and no real second is
/// spent: the transport, the wait and the clock are all injected.
final class HubPairingTests: XCTestCase {

    /// A hub that answers the claim route from a script of statuses.
    final class FakeHub: HubMirror.Transport, @unchecked Sendable {
        var answers: [(Int, [String: Any])]
        var seen: [[String: Any]] = []
        var throwsFirst = 0
        let lock = NSLock()
        init(_ answers: [(Int, [String: Any])]) { self.answers = answers }
        func post(_ path: String, json: [String: Any]) async throws -> (status: Int, body: Data) {
            try lock.withLock {
                seen.append(json)
                if throwsFirst > 0 {
                    throwsFirst -= 1
                    throw URLError(.notConnectedToInternet)
                }
            }
            let next: (Int, [String: Any]) = lock.withLock {
                answers.count > 1 ? answers.removeFirst() : (answers.first ?? (202, [:]))
            }
            return (next.0, try JSONSerialization.data(withJSONObject: next.1))
        }
        var calls: Int { lock.withLock { seen.count } }
    }

    private let base = URL(string: "https://hub.example.test")!

    private func pairing(_ hub: FakeHub, slept: SleepLog? = nil) -> HubPairing {
        let p = HubPairing(base: base, device: "test-mac", transport: hub)
        p.wait = { [weak slept] s in slept?.add(s) }
        return p
    }

    /// Records what the poller would have slept, so backoff is assertable.
    final class SleepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [TimeInterval] = []
        func add(_ s: TimeInterval) { lock.withLock { waits.append(s) } }
        var all: [TimeInterval] { lock.withLock { waits } }
    }

    // MARK: - The secret and the phrase

    func testTheCodeIsTheShapeTheHubValidates() {
        for _ in 0..<20 {
            let code = HubPairing.newCode()
            XCTAssertEqual(code.count, 43, "32 bytes, base64url, no padding")
            XCTAssertNil(code.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")),
                         "base64url, or the hub's regex refuses it: \(code)")
        }
        XCTAssertNotEqual(HubPairing.newCode(), HubPairing.newCode())
    }

    func testThePhraseMatchesTheHubsOwnDerivation() {
        // The hub computes it in lib/pairing.ts as the first six hex digits of
        // sha256(code), uppercased, split three and three. Two spellings of
        // one rule is how a person ends up comparing two different phrases,
        // so this pins the rule rather than the implementation.
        let code = "YqvDryNPFtgUAWaA0AsNuGkcogYhRIt6WSGDj_8zMWo"
        // The literal is what the hub's own function printed for this code,
        // run against lib/pairing.ts on 13 Sep. A recomputation in Swift would
        // only prove Swift agrees with Swift, and the failure this guards is
        // the two languages drifting: a person comparing two phrases that were
        // never going to match has no way to tell that from an attack.
        XCTAssertEqual(HubPairing.phrase(for: code), "F40-20E")
        let hex = SHA256.hash(data: Data(code.utf8))
            .map { String(format: "%02X", $0) }.joined().prefix(6)
        XCTAssertEqual(HubPairing.phrase(for: code),
                       String(hex.prefix(3)) + "-" + String(hex.suffix(3)))
    }

    func testADifferentCodeShowsADifferentPhrase() {
        // The whole defence against a mailed connect link: the page was handed
        // somebody else's code, so the phrase it prints is not the one on this
        // Mac's Setup row.
        XCTAssertNotEqual(HubPairing.phrase(for: HubPairing.newCode()),
                          HubPairing.phrase(for: HubPairing.newCode()))
    }

    func testTheConnectAddressCarriesTheCodeAndTheNameAndNothingElse() throws {
        let session = try XCTUnwrap(pairing(FakeHub([(202, [:])])).begin())
        let parts = try XCTUnwrap(URLComponents(url: session.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "hub.example.test")
        XCTAssertEqual(parts.path, "/connect")
        XCTAssertEqual(Set((parts.queryItems ?? []).map(\.name)), ["code", "device"])
        XCTAssertEqual(parts.queryItems?.first { $0.name == "code" }?.value, session.code)
        XCTAssertEqual(parts.queryItems?.first { $0.name == "device" }?.value, "test-mac")
        XCTAssertEqual(session.phrase, HubPairing.phrase(for: session.code))
        // Never the token's own address, and never a host from anywhere else.
        XCTAssertFalse(session.url.absoluteString.contains("token"))
    }

    // MARK: - Collecting

    func testATokenArrivesOnlyAfterSomebodyApproves() async throws {
        let hub = FakeHub([(202, [:]), (202, [:]),
                           (200, ["token": "hq_abc", "device_name": "Robert's mini"])])
        let log = SleepLog()
        let p = pairing(hub, slept: log)
        let session = try XCTUnwrap(p.begin())
        let outcome = await p.collect(session, every: 2)
        XCTAssertEqual(outcome, .connected(token: "hq_abc", device: "Robert's mini"))
        XCTAssertEqual(hub.calls, 3, "it polled until the answer changed")
        XCTAssertEqual(hub.seen.first?["code"] as? String, session.code,
                       "the code it invented is the only thing it ever sends")
        XCTAssertEqual(log.all, [2, 2], "a steady two seconds while nothing is happening")
    }

    func testSlowDownIsObeyed() async throws {
        let hub = FakeHub([(429, [:]), (429, [:]), (200, ["token": "hq_x"])])
        let log = SleepLog()
        let p = pairing(hub, slept: log)
        let session = try XCTUnwrap(p.begin())
        _ = await p.collect(session, every: 2)
        // RFC 8628: five more seconds each time the hub asks, and it never
        // speeds back up inside one attempt.
        XCTAssertEqual(log.all, [7, 12])
    }

    func testASpentCodeEndsTheAttemptRatherThanPollingOn() async throws {
        let hub = FakeHub([(410, ["error": "expired_token"])])
        let p = pairing(hub)
        let session = try XCTUnwrap(p.begin())
        let outcome = await p.collect(session, every: 2)
        XCTAssertEqual(outcome, .expired)
        XCTAssertEqual(hub.calls, 1)
    }

    func testAMalformedRequestIsRefusedNotRetried() async throws {
        let hub = FakeHub([(400, ["error": "invalid_request"])])
        let p = pairing(hub)
        let session = try XCTUnwrap(p.begin())
        guard case .refused = await p.collect(session, every: 2) else {
            return XCTFail("a 400 is the hub refusing, not a reason to keep asking")
        }
        XCTAssertEqual(hub.calls, 1)
    }

    func testAWifiBlipDoesNotCostThePairing() async throws {
        let hub = FakeHub([(200, ["token": "hq_survived"])])
        hub.throwsFirst = 3
        let p = pairing(hub)
        let session = try XCTUnwrap(p.begin())
        let outcome = await p.collect(session, every: 1)
        XCTAssertEqual(outcome, .connected(token: "hq_survived", device: "test-mac"))
        XCTAssertEqual(hub.calls, 4, "three failures, then the answer")
    }

    func testAHubThatNeverAnswersIsReported() async throws {
        let hub = FakeHub([(200, ["token": "never reached"])])
        hub.throwsFirst = 50
        let p = pairing(hub)
        let session = try XCTUnwrap(p.begin())
        guard case .failed = await p.collect(session, every: 1) else {
            return XCTFail("ten failures in a row is a hub that has gone away")
        }
        XCTAssertEqual(hub.calls, 10, "it stops asking rather than filling the window")
    }

    func testNobodyApprovingIsATimeoutNotASuccess() async throws {
        let hub = FakeHub([(202, [:])])
        let p = pairing(hub)
        // A clock that runs a minute per poll, so the ten-minute window closes
        // in ten calls instead of ten minutes.
        let ticks = Counter()
        p.now = { Date(timeIntervalSince1970: 1_000_000 + 60 * Double(ticks.next())) }
        let session = try XCTUnwrap(p.begin())
        let outcome = await p.collect(session, every: 2, within: 600)
        XCTAssertEqual(outcome, .timedOut)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
    }

    // MARK: - Keeping it

    func testAdoptWritesTheAddressBeforeTheKeyIsWorthAnything() throws {
        // Secrets is the machine's keychain, so this checks the half that is a
        // file: after adopting, the app's own reader finds the hub it was
        // connected to.
        let config = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hq-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: config) }
        try HubApp.setBaseURL(base, config: config)
        XCTAssertEqual(HubApp.baseURL(config: config), base)
    }
}
