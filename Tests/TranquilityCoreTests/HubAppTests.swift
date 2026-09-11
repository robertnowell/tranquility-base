import XCTest
@testable import TranquilityCore

/// The panel and the drainer must name a page the same way, or a door opens
/// on nothing. These pin the rule and the address.
final class HubAppTests: XCTestCase {

    private let base = URL(string: "https://hq.example.test")!
    private let root = "/Users/x/Documents/agents"
    private let session = "0d04e845-65ff-488f-983c-58f371d661ed"

    func testSlugIsThePathUnderTheAgentDirectoryWithSlashesFolded() {
        let hit = HubApp.locate("\(root)/\(session)/2026-09-07-cloud-app/index.html", root: root)
        XCTAssertEqual(hit?.session, session)
        XCTAssertEqual(hit?.slug, "2026-09-07-cloud-app-index")
        let flat = HubApp.locate("\(root)/\(session)/the-build-plan.html", root: root)
        XCTAssertEqual(flat?.slug, "the-build-plan")
    }

    func testTheHubItselfNamesTheAgentNotAPage() {
        let hit = HubApp.locate("\(root)/\(session)/index.html", root: root)
        XCTAssertEqual(hit?.session, session)
        XCTAssertNil(hit?.slug)
    }

    func testOutsideTheArchiveIsNotAPage() {
        XCTAssertNil(HubApp.locate("/Users/x/Projects/site/index.html", root: root))
        XCTAssertNil(HubApp.locate("\(root)/\(session)/notes.md", root: root))
    }

    func testTheAddressCarriesSessionAndSlug() {
        let url = HubApp.openURL(session: session, slug: "the-build-plan", base: base)
        XCTAssertEqual(url?.absoluteString,
                       "https://hq.example.test/open?session=\(session)&slug=the-build-plan")
        XCTAssertEqual(HubApp.openURL(session: session, base: base)?.absoluteString,
                       "https://hq.example.test/open?session=\(session)")
    }

    func testNoAppMeansNoAddress() {
        XCTAssertNil(HubApp.openURL(session: session, slug: "x", base: nil))
        XCTAssertNil(HubApp.openURL(forReportPath: "\(root)/\(session)/a.html", base: nil))
    }

    func testConfigIsReadOnlyWhenItIsAnHTTPAddress() throws {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tranquility-tests/hubapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = dir.appendingPathComponent("hq.json")
        try #"{"app":{"base_url":"https://hq.example.test/"}}"#.write(to: cfg, atomically: true, encoding: .utf8)
        XCTAssertEqual(HubApp.baseURL(config: cfg)?.absoluteString, "https://hq.example.test")
        try #"{"app":{"base_url":"file:///nope"}}"#.write(to: cfg, atomically: true, encoding: .utf8)
        XCTAssertNil(HubApp.baseURL(config: cfg))
        try #"{"roots":{}}"#.write(to: cfg, atomically: true, encoding: .utf8)
        XCTAssertNil(HubApp.baseURL(config: cfg))
    }
}
