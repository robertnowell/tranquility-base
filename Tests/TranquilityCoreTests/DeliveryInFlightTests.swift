import Foundation
import XCTest
@testable import TranquilityCore

/// The grid called a session idle for the whole time the app was delivering
/// words to it — reported 10 Aug, "it shows as idle in the gap between when I
/// dispatched audio and when it's confirmed as being sent".
///
/// The window itself is trivial. What is worth testing is the CEILING, because
/// the clear-sites are many and the failure mode of a missed one is a lamp that
/// lies indefinitely — the same failure `SessionActivity.freshness` exists to
/// prevent on the transcript side of the seam.
final class DeliveryInFlightTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    func testAsessionIsNotInFlightUntilItBegins() {
        let flight = DeliveryInFlight()
        XCTAssertFalse(flight.isInFlight("s1", now: t0))
    }

    func testTheWindowOpensAtTheCapturesCloseAndClosesOnTheOutcome() {
        var flight = DeliveryInFlight()
        flight.began(sessionId: "s1", at: t0)
        XCTAssertTrue(flight.isInFlight("s1", now: t0.addingTimeInterval(5)))
        flight.finished(sessionId: "s1")
        XCTAssertFalse(flight.isInFlight("s1", now: t0.addingTimeInterval(5)))
    }

    /// Two replies to two agents is the ordinary case, not an edge one: the
    /// point of the grid is that several sessions are live at once.
    func testDeliveriesAreTrackedPerSession() {
        var flight = DeliveryInFlight()
        flight.began(sessionId: "s1", at: t0)
        flight.began(sessionId: "s2", at: t0)
        flight.finished(sessionId: "s1")
        XCTAssertFalse(flight.isInFlight("s1", now: t0))
        XCTAssertTrue(flight.isInFlight("s2", now: t0))
    }

    /// The load-bearing one. A clear-site missed in either half of the reply
    /// flow must cost seconds, never the rest of the session's life.
    func testTheCeilingReleasesALampNobodyCleared() {
        var flight = DeliveryInFlight()
        flight.began(sessionId: "s1", at: t0)
        let justInside = t0.addingTimeInterval(DeliveryInFlight.ceiling - 1)
        let justOutside = t0.addingTimeInterval(DeliveryInFlight.ceiling + 1)
        XCTAssertTrue(flight.isInFlight("s1", now: justInside))
        XCTAssertFalse(flight.isInFlight("s1", now: justOutside))
    }

    /// The real window — transcription, a 4s undo countdown, a 250ms settle, up
    /// to 10s of read-back and a 3s retry — has to fit inside the ceiling with
    /// room to spare, or the ceiling becomes a second deadline the user feels.
    func testTheCeilingClearsTheSlowestHonestDelivery() {
        let worstCaseDispatch: TimeInterval = 4 + 0.25 + 10 + 3
        XCTAssertGreaterThan(DeliveryInFlight.ceiling, worstCaseDispatch * 2)
    }

    func testPruningDropsOnlyExpiredEntries() {
        var flight = DeliveryInFlight()
        flight.began(sessionId: "old", at: t0)
        flight.began(sessionId: "new", at: t0.addingTimeInterval(DeliveryInFlight.ceiling))
        flight.prune(now: t0.addingTimeInterval(DeliveryInFlight.ceiling + 1))
        XCTAssertEqual(flight.inFlightSessions(now: t0.addingTimeInterval(DeliveryInFlight.ceiling + 1)),
                       ["new"])
    }

    /// Pruning is housekeeping, not correctness: an unpruned expired entry is
    /// already invisible to the lamp. Stated as a test so a later change that
    /// makes `prune` load-bearing has to break this first.
    func testAnExpiredEntryIsInvisibleEvenWithoutPruning() {
        var flight = DeliveryInFlight()
        flight.began(sessionId: "s1", at: t0)
        XCTAssertTrue(flight.inFlightSessions(now: t0.addingTimeInterval(DeliveryInFlight.ceiling + 1)).isEmpty)
    }
}
