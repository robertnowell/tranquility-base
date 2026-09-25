import XCTest
@testable import TranquilityCore

/// One app-level state about credits, derived from summaries as they finish.
///
/// The claims a person would feel: a floor summary is named for what it is,
/// out of credits is a door and not a fault, a Mac that was never on credits
/// is quiet, and the Settings row says what to do.
final class CreditStandingTests: XCTestCase {

    override func tearDown() { CreditStanding.reset() }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func receipt(available: String) -> GatewayReceipt {
        GatewayReceipt(id: "r", accountId: "a", operationId: "o", currency: "USD", chargedMicros: "20000",
                       pricebookVersion: "v", settledAt: "2026-09-15T00:00:00Z",
                       balanceAfter: GatewayBalance(availableMicros: available, reservedMicros: "0", ledgerSequence: "9"))
    }

    func testAReceiptIsHistoryNotCurrentStanding() {
        let s = CreditStanding.from(receipt: receipt(available: "9480000"), failure: nil, provider: "tranquility-gateway", now: now)
        XCTAssertNil(s)
        XCTAssertEqual(CreditStanding.good(availableMicros: "9480000", at: now).detail,
                       "$9.48 at last balance check · summaries use credits")
        XCTAssertEqual(CreditStanding.from(receipt: receipt(available: "9480000"),
                                          failure: .refused(code: "insufficient_credit", operationId: nil),
                                          provider: "tranquility-gateway", now: now), .floored(.outOfCredits, at: now))
    }

    func testEachRefusalNamesItsResolution() {
        func standing(_ code: String) -> CreditStanding? {
            CreditStanding.from(receipt: nil, failure: .refused(code: code, operationId: nil), provider: "deterministic-fallback", now: now)
        }
        XCTAssertEqual(standing("insufficient_credit"), .floored(.outOfCredits, at: now))
        XCTAssertEqual(standing("insufficient_credit")?.line, "Add credits")
        XCTAssertEqual(standing("connection_rejected"), .floored(.connectAgain, at: now))
        XCTAssertEqual(standing("auth_required"), .floored(.connectAgain, at: now))
        // Not answers about the account (ruled 22 Sep): a provider fault, an
        // unreachable service and a code this build does not know leave the
        // last standing where it was.
        XCTAssertNil(standing("provider_failed"))
        XCTAssertNil(standing("service_unavailable"))
        XCTAssertNil(standing("something_new"))
        // Not on credits at all: the chain went on to the person's own key,
        // so this is not a floor. It is still a line, because the fix is theirs.
        XCTAssertEqual(standing("rebinding_required"), .notOnCredits(connectAgain: true))
        XCTAssertEqual(standing("rebinding_required")?.line, "Sign in for credits")
        XCTAssertEqual(standing("not_connected"), .notOnCredits(connectAgain: false))
        XCTAssertNil(standing("not_connected")?.line)
        XCTAssertNil(CreditStanding.from(receipt: nil, failure: .outcomeUnknown(operationId: "o"), provider: "deterministic-fallback", now: now))
        XCTAssertNil(CreditStanding.from(receipt: nil, failure: .invalidResponse, provider: "deterministic-fallback", now: now))
    }

    func testASummaryThatNeverWentNearCreditsSaysNothing() {
        XCTAssertNil(CreditStanding.from(receipt: nil, failure: nil, provider: "anthropic", now: now))
    }

    func testObserversHearEachChangeOnceAndTheCurrentValueOnJoining() {
        final class Heard: @unchecked Sendable { var all: [CreditStanding] = []; let lock = NSLock() }
        let heardBox = Heard()
        CreditStanding.observe { s in heardBox.lock.lock(); heardBox.all.append(s); heardBox.lock.unlock() }
        CreditStanding.set(.floored(.outOfCredits, at: now))
        CreditStanding.set(.floored(.outOfCredits, at: now))
        CreditStanding.set(.good(availableMicros: "1", at: now))
        XCTAssertEqual(heardBox.all, [.notOnCredits(connectAgain: false), .floored(.outOfCredits, at: now), .good(availableMicros: "1", at: now)])
        XCTAssertEqual(CreditStanding.current, .good(availableMicros: "1", at: now))
    }

    func testTheCreditsRowFollowsTheStanding() {
        func row(_ standing: CreditStanding) -> Prerequisites.State {
            let probes = Prerequisites.Probes(tmuxPath: { nil }, hooksProblem: { _ in nil },
                                              hasSecret: { _ in false }, creditStanding: { standing })
            return Prerequisites.snapshot(probes).first { $0.item == .credits }!
        }
        let good = row(.good(availableMicros: "9480000", at: now))
        XCTAssertTrue(good.satisfied); XCTAssertFalse(good.attention)
        let fresh = row(.onCredits)
        XCTAssertFalse(fresh.satisfied); XCTAssertFalse(fresh.attention, "a stored token is not verified readiness")
        let out = row(.floored(.outOfCredits, at: now))
        XCTAssertFalse(out.satisfied); XCTAssertTrue(out.attention)
        XCTAssertTrue(out.detail.hasPrefix("starting credits used"))
        let quiet = row(.notOnCredits(connectAgain: false))
        XCTAssertFalse(quiet.satisfied); XCTAssertFalse(quiet.attention, "a Mac never on credits is quiet")
        XCTAssertEqual(Prerequisites.Item.credits.fixLabel, "Sign in")
        XCTAssertFalse(Prerequisites.Item.credits.isRequired)
        XCTAssertEqual(Prerequisites.Item(id: "credits"), .credits)
        XCTAssertTrue(Prerequisites.items(harnesses: [], providers: []).contains(.credits))
    }

    /// Out of credits is amber with or without a pasted Anthropic key. That
    /// key covers summaries only; hearing and speaking run on credits and
    /// never fall to a key (#571). 22 Sep: the key hid the line while the
    /// transcripts were being refused.
    func testOutOfCreditsIsAmberEvenWithAnAnthropicKey() {
        let out = CreditStanding.floored(.outOfCredits, at: now)
        XCTAssertEqual(out.line(ownKey: false), "Add credits")
        XCTAssertEqual(out.line(ownKey: true), "Add credits")
        XCTAssertTrue(out.needsAttention(ownKey: true))
        XCTAssertTrue(out.detail(ownKey: true).contains("your own keys carry on"))
        let probes = Prerequisites.Probes(tmuxPath: { nil }, hooksProblem: { _ in nil },
                                          hasSecret: { $0 == .anthropicAPIKey }, creditStanding: { out })
        let row = Prerequisites.snapshot(probes).first { $0.item == .credits }!
        XCTAssertTrue(row.attention, "a summaries key does not pay for the microphone")
    }

    /// Every amber line is something to do, never a fault (ruled 22 Sep).
    func testEveryLineNamesAnAction() {
        let lines = [CreditStanding.floored(.outOfCredits, at: now), .floored(.connectAgain, at: now),
                     .notOnCredits(connectAgain: true)].compactMap(\.line)
        XCTAssertEqual(lines, ["Add credits", "Sign in for credits", "Sign in for credits"])
        for line in lines {
            XCTAssertTrue(line.hasPrefix("Add") || line.hasPrefix("Sign in"), line)
        }
    }

    func testTheTelemetryTokenNeverCarriesTheBalance() {
        XCTAssertEqual(CreditStanding.good(availableMicros: "9480000", at: now).token, "on_credits")
        XCTAssertEqual(CreditStanding.floored(.outOfCredits, at: now).token, "out_of_credits")
    }
}
