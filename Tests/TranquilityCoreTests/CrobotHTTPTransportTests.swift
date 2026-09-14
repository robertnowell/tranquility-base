import XCTest
@testable import TranquilityCore

/// The URL the gateway actually receives, and what a wrong one looks like.
///
/// Both of these exist because the live run found what no fixture could: a
/// query string built by `appendingPathComponent` produced a URL that matched
/// no route, and the gateway answered 200 with its own web page.
final class CrobotHTTPTransportTests: XCTestCase {

    private let base = URL(string: "https://crobot.example.test")!

    /// `appendingPathComponent` percent-encodes everything it is given, `?`
    /// included. Measured live 14 Sep: `/api/v1/tasks%3Flimit=200` matches no
    /// route, falls through to the single page app and returns HTML.
    func testAQueryStringIsNotAPathComponent() {
        let wrong = base.appendingPathComponent("api/v1/tasks?limit=200")
        XCTAssertTrue(wrong.absoluteString.contains("%3F"),
                      "this is the bug, pinned: \(wrong.absoluteString)")

        var parts = URLComponents(
            url: base.appendingPathComponent("api/v1/tasks"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "limit", value: "200")]
        XCTAssertEqual(parts.url?.absoluteString,
                       "https://crobot.example.test/api/v1/tasks?limit=200")
        XCTAssertFalse(parts.url!.absoluteString.contains("%3F"))
    }

    /// A 200 carrying HTML is not success. On this gateway it is the normal
    /// shape of a wrong URL, because anything unrouted falls through to the
    /// web app, so it must be named rather than left to fail as a JSON
    /// decoding error about an unexpected '<'.
    func testHTMLIsRefusedByNameRatherThanAsADecodingError() {
        let error = CrobotHTTPTransport.Gateway.servedThePage("api/v1/tasks")
        XCTAssertTrue("\(error)".contains("matched no route"), "\(error)")
        XCTAssertTrue("\(error)".contains("api/v1/tasks"))
    }

    func testAStatusFailureKeepsItsCodeAndBody() {
        let error = CrobotHTTPTransport.Gateway.status(502, "upstream gone")
        XCTAssertTrue("\(error)".contains("502"))
        XCTAssertTrue("\(error)".contains("upstream gone"))
    }

    /// The proxy the shared OpenCode client talks to sits under the task, and
    /// the task id is a path component, so it IS percent-encoded correctly.
    func testTheTaskIdIsEscapedAsAPathComponent() {
        let t = CrobotHTTPTransport(base: base, key: "jrv_probe")
        XCTAssertEqual(t.taskURL("ui-ts084zp8h42b")?.absoluteString,
                       "https://crobot.example.test/tasks/ui-ts084zp8h42b")
    }
}
