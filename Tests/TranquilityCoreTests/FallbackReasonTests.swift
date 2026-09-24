import XCTest
@testable import TranquilityCore

/// The panel line under a system-voice read. On 24 Sep it read
/// `refused(code: "no_audio", operationId: Optional("…"))`, an operation id
/// the person can do nothing with. Parsed from the error's type, in words.
final class FallbackReasonTests: XCTestCase {
    func testGatewayRefusalsBecomeWords() {
        XCTAssertEqual(FallbackReason(ManagedSummaryFailure.refused(code: "insufficient_credit", operationId: "x")), .creditsSpent)
        XCTAssertEqual(FallbackReason(ManagedSummaryFailure.refused(code: "no_audio", operationId: "x")), .clipLost)
        XCTAssertEqual(FallbackReason(ManagedSummaryFailure.refused(code: "already_bought", operationId: "x")), .clipLost)
        XCTAssertEqual(FallbackReason(ManagedSummaryFailure.outcomeUnknown(operationId: "x")), .unreachable)
        XCTAssertEqual(FallbackReason(URLError(.timedOut)), .unreachable)
        XCTAssertEqual(FallbackReason(ManagedSummaryFailure.refused(code: "something_new", operationId: "x")), .other)
    }

    /// No reason ever shows an id, a code, or Swift's own spelling of an error.
    func testNoReasonLeaksInternals() {
        for reason in [FallbackReason.creditsSpent, .clipLost, .keyRejected, .cutOff, .unreachable, .other] {
            for leak in ["refused(", "operationId", "Optional", "code:", "_"] {
                XCTAssertFalse(reason.words.contains(leak), "\(reason): \(reason.words)")
            }
        }
    }
}
