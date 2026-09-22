import XCTest
@testable import TranquilityCore

final class NetworkPathTests: XCTestCase {
    /// Online or not, the wait is bounded: the launch check must never park
    /// forever behind a network that does not come.
    func testWaitReturnsWithinItsTimeoutEitherWay() async {
        let path = NetworkPath()
        let start = ContinuousClock.now
        await path.waitUntilOnline(timeout: .milliseconds(300))
        await path.waitUntilOnline(timeout: .milliseconds(300))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }
}
