import XCTest
import WebKit
@testable import TranquilityCore

final class HubPageAddressTests: XCTestCase {
    private let base = URL(string: "https://hq.example.test")!

    func testAHubAddressBecomesAnInAppAddressAndBack() {
        let hub = URL(string: "https://hq.example.test/open?session=abc&slug=plan#top")!
        let inApp = HubPage.inApp(hub, base: base)
        XCTAssertEqual(inApp?.absoluteString, "hub://hq.example.test/open?session=abc&slug=plan#top")
        XCTAssertEqual(HubPage.onHub(inApp!, base: base), hub)
    }

    func testOnlyTheHubItselfIsTakenIn() {
        for other in ["https://hq.example.test.evil.example/d/x", "http://hq.example.test/d/x",
                      "https://user:pw@hq.example.test/d/x", "https://example.com/"] {
            XCTAssertNil(HubPage.inApp(URL(string: other)!, base: base), other)
        }
        XCTAssertNil(HubPage.onHub(URL(string: "hub://elsewhere.test/d/x")!, base: base))
        XCTAssertNil(HubPage.inApp(URL(string: "https://hq.example.test/")!, base: nil))
    }

    func testTheLoaderAnswersOnlyThePageBeingOpened() {
        let page = URL(string: "hub://hq.example.test/d/1")!
        var main = URLRequest(url: page)
        main.mainDocumentURL = page
        XCTAssertTrue(HubPage.mayServe(main))
        var sub = URLRequest(url: URL(string: "hub://hq.example.test/d/2")!)
        sub.mainDocumentURL = page
        XCTAssertFalse(HubPage.mayServe(sub), "a page's own request for another document")
        XCTAssertFalse(HubPage.mayServe(URLRequest(url: URL(string: "hub://hq.example.test/d/3")!)))
    }

    func testOnlyARawDocumentCountsAsAPage() {
        XCTAssertTrue(HubPage.isDocument(URL(string: "https://h/d/5b0e/raw")!))
        XCTAssertFalse(HubPage.isDocument(URL(string: "https://h/a/5b0e")!))
        XCTAssertFalse(HubPage.isDocument(URL(string: "https://h/sign-in")!))
    }

    func testEveryPageIsSandboxedWithTheNetworkClosed() {
        XCTAssertTrue(HubPage.policy.contains("sandbox allow-scripts"))
        XCTAssertFalse(HubPage.policy.contains("allow-same-origin"))
        XCTAssertTrue(HubPage.policy.contains("connect-src 'none'"))
    }
}

/// The locks, run in a real WebKit view rather than asserted as strings.
/// The 29 Sep probe is the reason: the leak it found passes every string test.
@MainActor
final class HubPageViewTests: XCTestCase {
    private let base = URL(string: "https://hq.example.test")!

    /// Records what the loader was asked to fetch, and serves one page.
    final class Hub: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        let pages: [String: String]
        init(_ pages: [String: String]) { self.pages = pages }
        var fetched: [String] { lock.withLock { asked } }
        func fetch(_ arg: String) -> Result<(html: String, landed: URL), HubRead.Failure> {
            lock.withLock { asked.append(arg) }
            let url = URL(string: arg)!
            if url.path == "/open" {
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "slug" }?.value ?? "missing"
                return .success((pages[id] ?? "", URL(string: "https://hq.example.test/d/\(id)/raw")!))
            }
            let id = url.lastPathComponent
            guard let html = pages[id] else { return .failure(.http(404)) }
            return .success((html, URL(string: "https://hq.example.test/d/\(id)/raw")!))
        }
    }

    private func make(_ hub: Hub) -> HubPageView {
        let loader = HubDocumentLoader(base: base) { arg in hub.fetch(arg) }
        let view = HubPageView(base: base, loader: loader)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        return view
    }

    private func eval(_ view: HubPageView, _ js: String) async -> String {
        (try? await view.webView.evaluateJavaScript(js)).map { "\($0)" } ?? "<error>"
    }

    private func settle(_ seconds: Double = 1.5) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func waitForLoad(_ view: HubPageView, title: String) async {
        for _ in 0..<50 where view.webView.title != title { await settle(0.1) }
    }

    func testAPageRunsItsScriptsButCannotReachAnythingThroughTheLoader() async {
        let page = """
        <html><head><title>one</title></head><body><h1 id=h>static</h1>
        <iframe src="hub://hq.example.test/d/secret"></iframe>
        <script>
        document.getElementById('h').textContent = 'ran';
        fetch('hub://hq.example.test/d/secret').then(r => r.text())
          .then(t => document.body.dataset.leak = t).catch(() => document.body.dataset.leak = 'refused');
        fetch('https://example.com/', {mode: 'no-cors'}).then(() => document.body.dataset.net = 'open')
          .catch(() => document.body.dataset.net = 'closed');
        </script></body></html>
        """
        let hub = Hub(["one": page, "secret": "SECRET-DOCUMENT"])
        let view = make(hub)
        XCTAssertTrue(view.open(URL(string: "https://hq.example.test/d/one")!))
        await waitForLoad(view, title: "one")
        await settle()
        let ran = await eval(view, "document.getElementById('h').textContent")
        let leak = await eval(view, "document.body.dataset.leak")
        let net = await eval(view, "document.body.dataset.net")
        XCTAssertEqual(ran, "ran")
        XCTAssertEqual(leak, "refused")
        XCTAssertEqual(net, "closed")
        XCTAssertEqual(hub.fetched, ["https://hq.example.test/d/one"],
                       "the loader fetched only the page that was opened")
    }

    func testAHubLinkStaysInTheWindowAndAnyOtherGoesToTheBrowser() async {
        let page = """
        <html><head><title>one</title></head><body>
        <a id=hub href="/open?session=abc&slug=two">next</a>
        <a id=out href="https://example.com/elsewhere">out</a></body></html>
        """
        let hub = Hub(["one": page, "two": "<title>two</title><p>second</p>"])
        let view = make(hub)
        var external: [URL] = []
        view.openExternally = { external.append($0) }
        view.open(URL(string: "https://hq.example.test/d/one")!)
        await waitForLoad(view, title: "one")

        _ = await eval(view, "document.getElementById('out').click(); 1")
        await settle(0.5)
        XCTAssertEqual(external.map(\.absoluteString), ["https://example.com/elsewhere"])
        XCTAssertEqual(view.webView.title, "one", "an external link does not navigate the window")

        _ = await eval(view, "document.getElementById('hub').click(); 1")
        await waitForLoad(view, title: "two")
        XCTAssertEqual(view.webView.title, "two")
        XCTAssertEqual(view.hubURL?.absoluteString, "https://hq.example.test/open?session=abc&slug=two")
    }

    func testAScriptCannotNavigateTheWindowAway() async {
        let page = """
        <html><head><title>one</title></head><body>
        <script>setTimeout(() => { location.href = 'https://example.com/phish' }, 50)</script></body></html>
        """
        let view = make(Hub(["one": page]))
        var external: [URL] = []
        view.openExternally = { external.append($0) }
        view.open(URL(string: "https://hq.example.test/d/one")!)
        await waitForLoad(view, title: "one")
        await settle(0.5)
        XCTAssertEqual(view.webView.title, "one")
        XCTAssertTrue(external.isEmpty, "only a click may send a page to the browser")
    }

    func testAPageThatIsNotAPageSaysSo() async {
        let view = make(Hub([:]))
        view.open(URL(string: "https://hq.example.test/d/nothing")!)
        await waitForLoad(view, title: "No such page")
        XCTAssertEqual(view.webView.title, "No such page")
    }

    func testNothingButTheHubOpens() {
        let view = make(Hub([:]))
        XCTAssertFalse(view.open(URL(string: "https://example.com/d/x")!))
        XCTAssertFalse(view.open(URL(string: "file:///etc/passwd")!))
    }
}

/// The loader's own lock, apart from the page's policy. In a real view the
/// sandbox and connect-src already stop a page's fetch before it reaches the
/// loader, which is why removing this check did not fail the view tests: so
/// it is driven here directly, as a request that did get through would be.
@MainActor
final class HubDocumentLoaderTests: XCTestCase {
    final class FakeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var failed: Error?
        var body = Data()
        var finished = false
        init(_ r: URLRequest) { request = r }
        func didReceive(_ response: URLResponse) {}
        func didReceive(_ data: Data) { body.append(data) }
        func didFinish() { finished = true }
        func didFailWithError(_ error: any Error) { failed = error }
    }

    func testARequestFromInsideAPageIsRefusedWithoutFetching() async {
        let base = URL(string: "https://hq.example.test")!
        let calls = HubPageViewTests.Hub(["secret": "SECRET"])
        let loader = HubDocumentLoader(base: base) { calls.fetch($0) }
        let web = WKWebView()
        var req = URLRequest(url: URL(string: "hub://hq.example.test/d/secret")!)
        req.mainDocumentURL = URL(string: "hub://hq.example.test/d/page")!
        let task = FakeTask(req)
        loader.webView(web, start: task)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(task.failed)
        XCTAssertTrue(task.body.isEmpty)
        XCTAssertTrue(calls.fetched.isEmpty, "the token was never used")
    }

    func testThePageBeingOpenedIsServedUnderThePolicy() async {
        let base = URL(string: "https://hq.example.test")!
        let loader = HubDocumentLoader(base: base) { HubPageViewTests.Hub(["page": "<p>hi</p>"]).fetch($0) }
        let url = URL(string: "hub://hq.example.test/d/page")!
        var req = URLRequest(url: url)
        req.mainDocumentURL = url
        let task = FakeTask(req)
        loader.webView(WKWebView(), start: task)
        for _ in 0..<20 where !task.finished { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(task.finished)
        XCTAssertEqual(String(decoding: task.body, as: UTF8.self), "<p>hi</p>")
    }
}
