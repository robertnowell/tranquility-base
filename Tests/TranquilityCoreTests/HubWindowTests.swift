import XCTest
import WebKit
@testable import TranquilityCore

@MainActor
final class HubWindowTests: XCTestCase {
    private func hub() -> HubWindow {
        let h = HubWindow(base: { URL(string: "https://hq.example.test") })
        h.activates = false
        h.dataStore = .nonPersistent()
        return h
    }

    /// A fresh install has no hq.json yet, and pairing must still open in the
    /// window, or its sign-in lands in the browser and the app and the hub are
    /// two logins (29 Sep).
    func testWithNoConfiguredHubThePairingPageStillOpensInTheWindow() {
        let h = HubWindow(base: { HubApp.defaultBaseURL })
        XCTAssertTrue(h.isHub(URL(string: "https://hq.tranquilitybase.dev/connect?code=x&device=y")!))
    }

    func testTheHubAndItsOwnSubdomainsAreTheHub() {
        let h = hub()
        XCTAssertTrue(h.isHub(URL(string: "https://hq.example.test/d/x")!))
        XCTAssertTrue(h.isHub(URL(string: "https://clerk.hq.example.test/v1/client")!))
        for other in ["https://hq.example.test.evil.example/", "http://hq.example.test/",
                      "https://example.test/", "file:///etc/passwd"] {
            XCTAssertFalse(h.isHub(URL(string: other)!), other)
        }
    }

    func testOnlyTheHubOpensInTheWindow() {
        let h = hub()
        XCTAssertFalse(h.show(URL(string: "https://example.com/d/x")!))
        XCTAssertNil(h.window)
        XCTAssertTrue(h.show(URL(string: "https://hq.example.test/open?session=abc")!))
        XCTAssertNotNil(h.window)
    }

    func testLinksOffTheHubGoToTheBrowserOnlyWhenClicked() {
        let h = hub()
        var opened: [URL] = []
        h.openExternally = { opened.append($0) }
        let out = URL(string: "https://example.com/elsewhere")!
        XCTAssertEqual(h.route(URL(string: "https://hq.example.test/a/1")!, mainFrame: true, clicked: true), .allow)
        XCTAssertEqual(h.route(out, mainFrame: true, clicked: false), .cancel)
        XCTAssertTrue(opened.isEmpty, "a script's own navigation goes nowhere")
        XCTAssertEqual(h.route(out, mainFrame: true, clicked: true), .cancel)
        XCTAssertEqual(opened, [out])
        let discuss = URL(string: "tranquilitybase://discuss?session=abc")!
        XCTAssertEqual(h.route(discuss, mainFrame: true, clicked: false), .cancel)
        XCTAssertEqual(opened.last, discuss, "Discuss reaches the app")
        XCTAssertEqual(h.route(out, mainFrame: false, clicked: false), .allow, "a document's own frames are the web app's")
    }
}

/// The window on the real hub, signed in, rendered, and written to a PNG.
/// Opt-in: TB_HUB_LIVE is an address to open (a one-time sign-in link works),
/// TB_HUB_SHOT where to write the picture. A throwaway store: nothing persists.
@MainActor
final class HubWindowLiveTests: XCTestCase {
    func testTheWindowShowsTheWebHub() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["TB_HUB_LIVE"], let url = URL(string: raw) else {
            throw XCTSkip("set TB_HUB_LIVE to run")
        }
        let h = HubWindow()
        h.activates = false
        h.dataStore = .nonPersistent()
        XCTAssertTrue(h.show(url))
        let then = env["TB_HUB_THEN"].flatMap(URL.init(string:))
        var went = false
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let path = h.webView?.url?.path ?? ""
            if let then, !went, !path.hasPrefix("/sign-in"), h.webView?.isLoading == false {
                went = true
                h.webView?.load(URLRequest(url: then))
                continue
            }
            if (then == nil || went), h.webView?.isLoading == false, !path.hasPrefix("/sign-in") { break }
        }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        XCTAssertFalse(h.webView?.url?.path.hasPrefix("/sign-in") ?? true, "signed in: \(h.webView?.url?.absoluteString ?? "")")
        if let path = env["TB_HUB_SHOT"], let web = h.webView {
            let image = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
