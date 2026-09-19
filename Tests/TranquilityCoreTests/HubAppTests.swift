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

    /// hq.json belongs to everything that writes pages, not to this app. The
    /// connect flow is the first time the panel writes it at all, and a
    /// serialise-what-I-know writer would have quietly deleted the roots the
    /// skills read and the keys the indexer sets.
    func testWritingTheBaseURLPreservesUnknownKeys() throws {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tranquility-tests/hubwrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = dir.appendingPathComponent("hq.json")
        try #"{"roots":{"agents":"~/Documents/agents"},"app":{"base_url":"https://old.example.test","theme":"archive"},"version":3}"#
            .write(to: cfg, atomically: true, encoding: .utf8)

        try HubApp.setBaseURL(URL(string: "https://new.example.test/")!, config: cfg)

        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: cfg)) as? [String: Any])
        XCTAssertEqual((obj["roots"] as? [String: Any])?["agents"] as? String, "~/Documents/agents")
        XCTAssertEqual(obj["version"] as? Int, 3)
        let app = try XCTUnwrap(obj["app"] as? [String: Any])
        XCTAssertEqual(app["theme"] as? String, "archive", "a key this app knows nothing about")
        XCTAssertEqual(app["base_url"] as? String, "https://new.example.test",
                       "and no trailing slash, so every path built on it is one slash")
        XCTAssertEqual(HubApp.baseURL(config: cfg)?.absoluteString, "https://new.example.test")
    }

    /// A machine that has never had one: the file is created, not required.
    func testWritingTheBaseURLIntoNothingCreatesIt() throws {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tranquility-tests/hubwrite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = dir.appendingPathComponent("nested/hq.json")
        try HubApp.setBaseURL(URL(string: "https://fresh.example.test")!, config: cfg)
        XCTAssertEqual(HubApp.baseURL(config: cfg)?.absoluteString, "https://fresh.example.test")
    }
}
