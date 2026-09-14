import XCTest
@testable import TranquilityCore

final class AgentMarksTests: XCTestCase {

    /// **Every agent in the grid has its own mark.** An agent added to the
    /// roster without one would draw a hole, and a hole in a five-tile grid is
    /// the first thing the eye lands on.
    func testEveryValidatedAgentHasAMark() {
        for entry in AgentRoster.validated {
            XCTAssertNotNil(AgentMarks.png(entry.id),
                            "\(entry.id) is offered in the grid with no logo")
        }
    }

    /// And the marks decode to real PNGs, at the size the tile draws.
    ///
    /// The PNG signature is checked rather than just the byte count, because a
    /// fetch that returns an HTML error page still has a byte count — which is
    /// exactly how two of these arrived on the first attempt, 403 and 429 saved
    /// under an `.ico` name.
    func testEveryMarkIsARealPNGAndNotAnErrorPage() {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for id in AgentMarks.known {
            guard let png = AgentMarks.png(id) else { return XCTFail("\(id) did not decode") }
            XCTAssertGreaterThan(png.count, 400, "\(id) is too small to be a mark")
            XCTAssertLessThan(png.count, 64_000, "\(id) is too large for a 44pt tile")
            XCTAssertEqual(Array(png.prefix(8)), signature,
                           "\(id) is not a PNG — an error page saved under the wrong name?")
        }
    }

    /// No mark is a duplicate of another. Two agents wearing one logo is the
    /// kind of thing that survives review and is obvious on screen.
    func testNoTwoAgentsShareAMark() {
        let all = AgentMarks.known.compactMap { AgentMarks.png($0) }
        XCTAssertEqual(all.count, Set(all).count, "two agents are wearing the same logo")
    }
}
