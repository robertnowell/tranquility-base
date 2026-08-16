import XCTest
@testable import TranquilityCore

/// A page has said what it is all along. These are the cases where the obvious
/// read gets it wrong — a slug in the title, a site name stapled on, a title so
/// long it is a sentence.
final class DocumentSummaryTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-summary-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    private func write(_ html: String) -> String {
        let path = dir.appendingPathComponent("index.html").path
        try? html.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testTheTitleElementIsUsed() {
        let p = write("<html><head><title>Program map and state legend</title></head><body></body></html>")
        XCTAssertEqual(ArtifactStore.summarize(path: p).title, "Program map and state legend")
    }

    /// Open Graph outranks the title element, as it does in every reader tool.
    func testOpenGraphWins() {
        let p = write("""
            <html><head><meta property="og:title" content="MOCR brand direction">
            <title>index</title></head><body></body></html>
            """)
        XCTAssertEqual(ArtifactStore.summarize(path: p).title, "MOCR brand direction")
    }

    /// Readability's actual rescue: a title under 15 characters is unusable, so
    /// the h1 is preferred. This is the case that turns "vd-grid-mock" into
    /// something a human wrote.
    func testAShortSlugTitleFallsBackToTheHeading() {
        let p = write("""
            <html><head><title>vd-grid-mock</title></head>
            <body><h1>Grid mock — three ways to not suck</h1></body></html>
            """)
        XCTAssertEqual(ArtifactStore.summarize(path: p).title,
                       "Grid mock — three ways to not suck")
    }

    func testASiteNameSuffixIsTrimmed() {
        let p = write("<html><head><title>The capture strip ruling — Tranquility Base</title></head></html>")
        XCTAssertEqual(ArtifactStore.summarize(path: p).title, "The capture strip ruling")
    }

    /// The specific half survives, whichever end it sits on.
    ///
    /// This reverses "a short head is never trimmed away", and cites a
    /// measurement rather than an argument (CLAUDE.md rule 4): one hub listed
    /// four different documents as "Intranet", "Tranquility Base",
    /// "Tranquility Base", "Tranquility Base", because the house writes
    /// "Site — Page" and the old rule always kept the head. A brand repeated
    /// down a list names nothing.
    func testTheSpecificHalfSurvivesEitherEnd() {
        let lead = write("<html><head><title>Kopi — the whole brief</title></head></html>")
        XCTAssertEqual(ArtifactStore.summarize(path: lead).title, "the whole brief")
        let trail = write("<html><head><title>The capture strip ruling — Tranquility Base</title></head></html>")
        XCTAssertEqual(ArtifactStore.summarize(path: trail).title, "The capture strip ruling")
    }

    /// The hover card's text: the meta description if there is one, else the
    /// first paragraph, with the markup taken out.
    func testTheBlurbPrefersTheDescription() {
        let p = write("""
            <html><head><title>A perfectly ordinary title here</title>
            <meta name="description" content="What the page argues."></head>
            <body><p>Something <b>else</b> entirely.</p></body></html>
            """)
        XCTAssertEqual(ArtifactStore.summarize(path: p).blurb, "What the page argues.")
    }

    func testTheBlurbFallsBackToTheFirstParagraphWithoutTags() {
        let p = write("""
            <html><head><title>A perfectly ordinary title here</title></head>
            <body><p>One page, <b>three</b> panels &amp; a legend.</p></body></html>
            """)
        XCTAssertEqual(ArtifactStore.summarize(path: p).blurb,
                       "One page, three panels & a legend.")
    }

    func testAMissingFileIsNotACrash() {
        let summary = ArtifactStore.summarize(path: "/tmp/does-not-exist-\(UUID()).html")
        XCTAssertNil(summary.title)
        XCTAssertNil(summary.blurb)
    }
}
