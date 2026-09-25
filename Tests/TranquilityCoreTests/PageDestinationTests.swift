import XCTest
@testable import TranquilityCore

/// Where a recorded page is READ. The hub for a page in the tree, the page's
/// own address for one outside it, the file only when it declares none.
final class PageDestinationTests: XCTestCase {

    func testAPageDeclaresItsAddressInAnyOfThreeSpellings() {
        XCTAssertEqual(ArtifactStore.liveAddress(inHead:
            "<html><head><link rel=\"canonical\" href=\"https://tranquilitybase.dev/\">")?.absoluteString,
            "https://tranquilitybase.dev/")
        XCTAssertEqual(ArtifactStore.liveAddress(inHead:
            "<meta property=\"og:url\" content=\"https://example.test/p\">")?.absoluteString,
            "https://example.test/p")
        XCTAssertEqual(ArtifactStore.liveAddress(inHead:
            "<meta content=\"https://pub.example.test/x\" name=\"intranet:url\">")?.absoluteString,
            "https://pub.example.test/x")
        // The archive's own tag outranks the page's canonical.
        XCTAssertEqual(ArtifactStore.liveAddress(inHead:
            "<link rel=\"canonical\" href=\"https://site.test/\"><meta name=\"intranet:url\" content=\"https://pub.test/a\">")?.absoluteString,
            "https://pub.test/a")
    }

    /// A canonical that is not somewhere to send anyone is not an address.
    func testOnlyAWebAddressCounts() {
        XCTAssertNil(ArtifactStore.liveAddress(inHead: "<link rel=\"canonical\" href=\"/\">"))
        XCTAssertNil(ArtifactStore.liveAddress(inHead: "<link rel=\"canonical\" href=\"file:///Users/x/a.html\">"))
        XCTAssertNil(ArtifactStore.liveAddress(inHead: "<link rel=\"canonical\" href=\"\">"))
        XCTAssertNil(ArtifactStore.liveAddress(inHead: "<html><head><title>plain</title></head>"))
    }

    func testTheDestinationIsHubThenLiveThenFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let site = tmp.appendingPathComponent("site/index.html")
        try FileManager.default.createDirectory(at: site.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<html><head><link rel=\"canonical\" href=\"https://tranquilitybase.dev/\"></head></html>"
            .write(to: site, atomically: true, encoding: .utf8)
        let plain = tmp.appendingPathComponent("plain.html")
        try "<html><head><title>x</title></head></html>".write(to: plain, atomically: true, encoding: .utf8)

        let base = URL(string: "https://hub.example.test")!
        // Outside the tree: the page's own address, whatever the hub config.
        XCTAssertEqual(HubApp.destination(forReportPath: site.path, base: base),
                       .live(URL(string: "https://tranquilitybase.dev/")!))
        XCTAssertEqual(HubApp.destination(forReportPath: site.path, base: nil),
                       .live(URL(string: "https://tranquilitybase.dev/")!))
        // Outside the tree and silent about itself: the file, and the door
        // will say so.
        XCTAssertEqual(HubApp.destination(forReportPath: plain.path, base: base), .file(plain.path))
        XCTAssertEqual(HubApp.destination(forReportPath: plain.path, base: base).url,
                       URL(fileURLWithPath: plain.path))
    }
}
