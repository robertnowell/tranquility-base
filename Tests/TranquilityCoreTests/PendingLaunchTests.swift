import XCTest
@testable import TranquilityCore

/// The promise a reply waits on when you answer a launch card before the agent
/// has registered. Measured 18 Aug: registration took five to nine seconds, and
/// a reply started three seconds in went to the PREVIOUS agent.
final class PendingLaunchTests: XCTestCase {
    private func launch() -> PendingLaunch {
        PendingLaunch(label: "Projects", directory: "/Users/x/Projects")
    }

    func testAResolvedLaunchAnswersImmediately() async {
        let l = launch()
        l.resolve(sessionId: "s-1")
        XCTAssertFalse(l.isPending)
        // No waiting at all: the common case is a reply that took longer to
        // speak than the agent took to come up.
        let started = Date()
        let id = await l.session(timeout: 30)
        XCTAssertEqual(id, "s-1")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testAWaiterIsReleasedWhenTheAgentArrives() async {
        let l = launch()
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            l.resolve(sessionId: "s-late")
        }
        let id = await l.session(timeout: 5)
        XCTAssertEqual(id, "s-late", "the words go to the agent that was launched")
    }

    /// The honest failure — a trust prompt nobody answered, Terminal refusing.
    /// It must end the wait rather than hang, because the card that says so is
    /// the only thing standing between the user and a silently dropped reply.
    func testAnAbandonedLaunchReleasesItsWaitersWithNothing() async {
        let l = launch()
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            l.abandon()
        }
        let id = await l.session(timeout: 5)
        XCTAssertNil(id)
        XCTAssertFalse(l.isPending)
    }

    func testTheWaitIsBounded() async {
        let l = launch()
        let id = await l.session(timeout: 0.3)
        XCTAssertNil(id, "a launch that never answers must not hold the reply forever")
        XCTAssertTrue(l.isPending, "and timing out is not the same as giving up on it")
    }

    /// A launch names one session for its whole life: a second resolve, or a
    /// resolve after abandonment, changes nothing.
    func testResolutionIsOnceAndOnlyOnce() async {
        let l = launch()
        l.resolve(sessionId: "first")
        l.resolve(sessionId: "second")
        let id = await l.session(timeout: 1)
        XCTAssertEqual(id, "first")

        let abandoned = launch()
        abandoned.abandon()
        abandoned.resolve(sessionId: "too-late")
        let none = await abandoned.session(timeout: 1)
        XCTAssertNil(none)
    }

    func testManyWaitersAllWakeOnOneResolution() async {
        let l = launch()
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            l.resolve(sessionId: "s-many")
        }
        // Two utterances inside the same launch window is a normal thing to do:
        // you answer the card, then add a sentence.
        async let a = l.session(timeout: 5)
        async let b = l.session(timeout: 5)
        let (first, second) = await (a, b)
        XCTAssertEqual(first, "s-many")
        XCTAssertEqual(second, "s-many")
    }
}
