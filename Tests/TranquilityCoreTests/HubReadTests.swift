import XCTest
@testable import TranquilityCore

/// Reading a page back out of the hub. The load-bearing test is the first
/// one: a bearer token goes to exactly one host, and the argument arrives
/// from a URL a web page put in front of the app.
final class HubReadTests: XCTestCase {

    private let hub = URL(string: "https://hq.tranquilitybase.dev")!
    private let doc = "cf2833fa-e988-4bcd-bbef-1e1dc0f9a6b7"

    func testTheTokenOnlyEverGoesToTheHub() {
        XCTAssertNil(HubRead.resolve("https://evil.example/d/\(doc)", base: hub))
        XCTAssertNil(HubRead.resolve("http://hq.tranquilitybase.dev/d/\(doc)", base: hub),
                     "plaintext is not the hub")
        XCTAssertNil(HubRead.resolve("https://hq.tranquilitybase.dev.evil.example/d/x", base: hub),
                     "a suffix is not a host")
        XCTAssertNil(HubRead.resolve("https://user:pw@hq.tranquilitybase.dev/d/x", base: hub))
        XCTAssertNil(HubRead.resolve("file:///etc/passwd", base: hub))
        XCTAssertNil(HubRead.resolve("https://hq.tranquilitybase.dev/d/x", base: nil),
                     "no hub configured, nowhere to send it")
    }

    func testTheShapesSomebodyActuallyHasInHand() {
        XCTAssertEqual(HubRead.resolve("https://hq.tranquilitybase.dev/d/\(doc)", base: hub)?.absoluteString,
                       "https://hq.tranquilitybase.dev/d/\(doc)")
        XCTAssertEqual(HubRead.resolve(doc, base: hub)?.absoluteString,
                       "https://hq.tranquilitybase.dev/d/\(doc)", "a bare document id")
        XCTAssertEqual(HubRead.resolve("  \(doc)\n", base: hub)?.absoluteString,
                       "https://hq.tranquilitybase.dev/d/\(doc)", "pasted with its whitespace")
        XCTAssertEqual(
            HubRead.resolve("https://hq.tranquilitybase.dev/open?session=abc&slug=plan", base: hub)?
                .absoluteString,
            "https://hq.tranquilitybase.dev/open?session=abc&slug=plan", "a page footer's address")
        XCTAssertNil(HubRead.resolve("not-a-thing", base: hub))
        XCTAssertNil(HubRead.resolve("", base: hub))
    }

    func testAMissingCredentialIsNotAFetchFailure() async {
        let r = await HubRead.fetch(doc, base: hub, token: nil,
                                    send: { _ in XCTFail("no request should be made"); throw CancellationError() })
        XCTAssertEqual(r, .failure(.notConnected))
    }

    func testARefusedHostNeverOpensASocket() async {
        let r = await HubRead.fetch("https://evil.example/d/\(doc)", base: hub, token: "t",
                                    send: { _ in XCTFail("no request should be made"); throw CancellationError() })
        XCTAssertEqual(r, .failure(.notTheHub("https://evil.example/d/\(doc)")))
    }

    func testTheTokenTravelsAsBearerAndTheBodyComesBack() async {
        var seen: URLRequest?
        let r = await HubRead.fetch(doc, base: hub, token: "sekret", send: { req in
            seen = req
            return (Data("<h1>hello</h1>".utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        XCTAssertEqual(r, .success("<h1>hello</h1>"))
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "authorization"), "Bearer sekret")
        XCTAssertEqual(seen?.url?.path, "/d/\(doc)")
    }

    func testAnUnhappyStatusIsReportedWithItsCode() async {
        let r = await HubRead.fetch(doc, base: hub, token: "t", send: { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        })
        XCTAssertEqual(r, .failure(.http(404)))
    }

    func testTextKeepsTheProseAndDropsTheMachinery() {
        let html = """
        <html><head><style>p{color:red}</style></head><body>
        <h1>The plan</h1><p>Two &amp; two.</p><script>alert(1)</script>
        <p>Three.</p></body></html>
        """
        let out = HubRead.text(html)
        XCTAssertTrue(out.contains("The plan"))
        XCTAssertTrue(out.contains("Two & two."))
        XCTAssertTrue(out.contains("Three."))
        XCTAssertFalse(out.contains("color:red"))
        XCTAssertFalse(out.contains("alert"))
    }

    // MARK: - The prompt the invitation opens with

    func testAHubPageIsOpenedWithTheCommandThatCanReadIt() {
        let p = DeepLink.openingPrompt(for: .page("https://hq.tranquilitybase.dev/d/\(doc)"),
                                       hubHost: "hq.tranquilitybase.dev")
        XCTAssertTrue(p.contains("tbase read https://hq.tranquilitybase.dev/d/\(doc)"), p)
    }

    func testAnyOtherPageIsStillJustRead() {
        let p = DeepLink.openingPrompt(for: .page("https://example.com/p/"),
                                       hubHost: "hq.tranquilitybase.dev")
        XCTAssertFalse(p.contains("tbase read"), p)
        XCTAssertTrue(p.contains("Read https://example.com/p/"), p)
    }

    /// The failure this would have had: `openingCommand` refuses a prompt
    /// carrying a quote, a backslash, a backtick or a dollar, and the session
    /// then opens BLANK with the prompt on the clipboard. Silent, and only on
    /// the path that a hub page takes.
    func testTheHubPromptStillSurvivesTheShell() {
        let p = DeepLink.openingPrompt(for: .page("https://hq.tranquilitybase.dev/d/\(doc)"),
                                       hubHost: "hq.tranquilitybase.dev")
        XCTAssertNotNil(DeepLink.openingCommand(base: "claude", prompt: p),
                        "a hub invitation must start holding its page, not blank")
    }
}

/// The redirect chain. Measured against the live hub on 13 Sep: `/d/<id>`
/// answered 200 with the token and `/open?session=&slug=` answered 401,
/// because URLSession drops `Authorization` when it follows a redirect and
/// `/open` is nothing BUT a redirect. Every page footer in the archive
/// carries the `/open` shape.
extension HubReadTests {

    private func reply(_ req: URLRequest, _ status: Int, location: String? = nil,
                       body: String = "") -> (Data, URLResponse) {
        (Data(body.utf8),
         HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil,
                         headerFields: location.map { ["location": $0] })!)
    }

    func testTheOpenShapeIsFollowedWithTheTokenStillOn() async {
        let hub = URL(string: "https://hq.tranquilitybase.dev")!
        var hops: [(String, String?)] = []
        let r = await HubRead.fetch(
            "https://hq.tranquilitybase.dev/open?session=abc&slug=plan",
            base: hub, token: "sekret",
            send: { req in
                hops.append((req.url!.path, req.value(forHTTPHeaderField: "authorization")))
                return req.url!.path == "/open"
                    ? self.reply(req, 302, location: "/d/cf2833fa-e988-4bcd-bbef-1e1dc0f9a6b7")
                    : self.reply(req, 200, body: "<h1>the plan</h1>")
            })
        XCTAssertEqual(r, .success("<h1>the plan</h1>"))
        XCTAssertEqual(hops.map(\.0), ["/open", "/d/cf2833fa-e988-4bcd-bbef-1e1dc0f9a6b7"])
        XCTAssertEqual(hops.map(\.1), ["Bearer sekret", "Bearer sekret"],
                       "the credential must survive the hop, which is the whole bug")
    }

    func testARedirectOffTheHubNeverCarriesTheToken() async {
        let hub = URL(string: "https://hq.tranquilitybase.dev")!
        var paths: [String] = []
        let r = await HubRead.fetch("cf2833fa-e988-4bcd-bbef-1e1dc0f9a6b7", base: hub, token: "t",
                                    send: { req in
            paths.append(req.url!.absoluteString)
            return self.reply(req, 302, location: "https://evil.example/collect")
        })
        XCTAssertEqual(r, .failure(.notTheHub("https://evil.example/collect")))
        XCTAssertEqual(paths.count, 1, "the second request is never made")
    }

    func testARedirectLoopStopsRatherThanSpinning() async {
        let hub = URL(string: "https://hq.tranquilitybase.dev")!
        var calls = 0
        let r = await HubRead.fetch("cf2833fa-e988-4bcd-bbef-1e1dc0f9a6b7", base: hub, token: "t",
                                    send: { req in
            calls += 1
            return self.reply(req, 302, location: "/d/cf2833fa-e988-4bcd-bbef-1e1dc0f9a6b7")
        })
        XCTAssertEqual(r, .failure(.http(310)))
        XCTAssertEqual(calls, HubRead.maxHops)
    }
}
