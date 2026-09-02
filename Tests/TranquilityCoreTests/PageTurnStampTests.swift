import XCTest
@testable import TranquilityCore

/// The page carrying the turn it was written in.
final class PageTurnStampTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func page(_ html: String, name: String = "p.html") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testTheStampGoesInTheHead() throws {
        let url = try page("<!doctype html><html><head><title>x</title></head><body>y</body></html>")
        HomeBase.stamp(page: url, turn: "2026-09-02T18:04:05Z")
        let out = try read(url)
        XCTAssertTrue(out.contains(#"<meta name="intranet:turn" content="2026-09-02T18:04:05Z">"#))
        XCTAssertLessThan(try XCTUnwrap(out.range(of: "intranet:turn")).lowerBound,
                          try XCTUnwrap(out.range(of: "</head>")).lowerBound,
                          "the stamp is metadata, so it sits in the head")
    }

    /// A hub is rewritten at every turn end. The second write must not add a
    /// second stamp, and must not move the first.
    func testASecondRenderChangesNothing() throws {
        let url = try page("<html><head></head><body>y</body></html>")
        HomeBase.stamp(page: url, turn: "2026-09-02T18:04:05Z")
        let first = try read(url)
        HomeBase.stamp(page: url, turn: "2026-09-02T19:00:00Z")
        XCTAssertEqual(try read(url), first, "declared beats inferred, including our own earlier stamp")
        XCTAssertEqual(first.components(separatedBy: "intranet:turn").count - 1, 1)
    }

    /// The load-bearing one. A refreshed mtime makes the page look just-written
    /// to the next artifact-hook run, which re-attributes it to whichever
    /// session last ran a shell command (16 Aug).
    func testTheFilesModificationTimeSurvives() throws {
        let url = try page("<html><head></head><body>y</body></html>")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        HomeBase.stamp(page: url, turn: "2026-09-02T18:04:05Z")
        let after = try XCTUnwrap(FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        XCTAssertEqual(after.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(try read(url).contains("intranet:turn"), "and it still got stamped")
    }

    /// Real pages in this archive are not all well-formed documents.
    func testAPageWithNoHeadIsStampedAfterItsTitle() throws {
        let url = try page("<!doctype html>\n<title>bare</title>\n<style>a{}</style>\n<p>y</p>")
        HomeBase.stamp(page: url, turn: "2026-09-02T18:04:05Z")
        let out = try read(url)
        XCTAssertTrue(out.contains("intranet:turn"))
        XCTAssertLessThan(try XCTUnwrap(out.range(of: "intranet:turn")).lowerBound,
                          try XCTUnwrap(out.range(of: "<style>")).lowerBound)
    }

    func testAFragmentIsStampedAtTheTop() throws {
        let url = try page("<p>just a fragment</p>")
        HomeBase.stamp(page: url, turn: "2026-09-02T18:04:05Z")
        XCTAssertTrue(try read(url).hasPrefix(#"<meta name="intranet:turn""#))
    }

    /// The window, and the rule the hub renders by.
    func testTurnOwnerPicksTheTurnThatWasRunning() {
        let t0 = Date()                                   // newest
        let t1 = t0.addingTimeInterval(-600)
        let t2 = t0.addingTimeInterval(-1200)
        let turns = [t0, t1, t2].map { HomeBase.Turn(at: $0, topic: "t", happened: "h") }
        // A turn's stamp is when its brief was written, which is when the turn
        // ENDED. So a page belongs to the turn that was still running when it
        // was saved: after the previous turn's brief, at or before its own.
        XCTAssertEqual(HomeBase.turnOwner(of: t1.addingTimeInterval(60), in: turns), 0,
                       "written a minute after t1's brief — that is turn 0's work")
        XCTAssertEqual(HomeBase.turnOwner(of: t1.addingTimeInterval(-60), in: turns), 1,
                       "written before t1's brief and after t2's — turn 1")
        XCTAssertEqual(HomeBase.turnOwner(of: t2.addingTimeInterval(-60), in: turns), 2,
                       "older than every turn falls to the oldest one shown")
        XCTAssertEqual(HomeBase.turnOwner(of: t0.addingTimeInterval(3600), in: turns), 0,
                       "written after the last brief belongs to the work in flight")
    }
}
