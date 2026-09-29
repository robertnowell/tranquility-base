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

    /// "Open Image in New Window" on an image the page carries inline (29 Sep):
    /// the app decodes it; a data: page is never loaded.
    func testAnInlineImageIsDecodedHereAndADataPageIsNotLoaded() {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let image = HubWindow.inlineImage(URL(string: "data:image/png;base64,\(png)")!)
        XCTAssertEqual(image?.size.width, 1)
        XCTAssertNil(HubWindow.inlineImage(URL(string: "data:text/html;base64,PGgxPng8L2gxPg==")!))
        XCTAssertEqual(hub().route(URL(string: "data:text/html,<h1>x</h1>")!, mainFrame: true, clicked: false), .cancel)
    }

    func testTheLogNeverCarriesASignInTicket() {
        let d = HubWindow.describe(URL(string: "https://hq.example.test/sign-in?__clerk_ticket=secret")!)
        XCTAssertEqual(d, "https://hq.example.test/sign-in")
    }

    /// One sign-in (29 Sep): the app follows the hub window's session.
    func testSigningOutInTheHubSignsTheAppOutOnceAndAFirstLoadDoesNot() {
        let h = hub()
        var outs = 0, ins: [String] = []
        h.onSignedOut = { outs += 1 }
        h.onSignedIn = { ins.append($0) }
        h.hubSaid(user: nil)            // opened on the sign-in page: not a sign-out
        XCTAssertEqual(outs, 0)
        h.hubSaid(user: "user_1")       // signed in here
        XCTAssertEqual(ins, ["user_1"])
        h.hubSaid(user: "user_1")       // the next page says the same: nothing
        XCTAssertEqual(ins, ["user_1"])
        h.hubSaid(user: nil)            // signed out
        h.hubSaid(user: nil)            // and the sign-in page it lands on
        XCTAssertEqual(outs, 1)
    }

    func testAWindowThatOpensSignedInIsASignInNotASignOut() {
        let h = hub()
        var outs = 0, ins = 0
        h.onSignedOut = { outs += 1 }
        h.onSignedIn = { _ in ins += 1 }
        h.hubSaid(user: "user_1")
        XCTAssertEqual(outs, 0)
        XCTAssertEqual(ins, 1)
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

final class HubDoorLinkTests: XCTestCase {
    func testTheHubLinkCarriesItsAddress() {
        let page = "https://hq.example.test/open?session=abc&slug=plan"
        let link = URL(string: "tranquilitybase://hub?url=" + page.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
        guard case let .hub(url) = DeepLink.parse(link) else { return XCTFail("not a hub link") }
        XCTAssertEqual(url?.absoluteString, page)
        guard case let .hub(none) = DeepLink.parse(URL(string: "tranquilitybase://hub")!) else { return XCTFail() }
        XCTAssertNil(none)
    }

    @MainActor
    func testTheMarkerNamesTheBundleThatWroteIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hq/hub-window")
        HubWindow.announce(bundle: URL(fileURLWithPath: "/Applications/Tranquility Base.app"), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "/Applications/Tranquility Base.app")
    }
}

/// One code (29 Sep): the app presses its own Connect.
@MainActor
final class HubWindowSelfConnectTests: XCTestCase {
    private func hub() -> HubWindow {
        let h = HubWindow(base: { URL(string: "https://hq.example.test") })
        h.activates = false
        h.dataStore = .nonPersistent()
        return h
    }


    /// The app opened its own Connect page with a code it invented: the
    /// window recognises it and approves without a phrase to compare.
    func testTheAppsOwnConnectPageIsRecognised() {
        let h = hub()
        h.ownConnectCode = { "own-code_1" }
        let url = URL(string: "https://hq.example.test/connect?code=own-code_1&device=robaroni-mac")!
        XCTAssertEqual(h.selfConnectCode(url), "own-code_1")
    }

    /// The attack the phrase exists for: a stranger's link carries THEIR code.
    /// It must reach the phrase screen, never an automatic Connect.
    func testALinkWithSomebodyElsesCodeIsNeverApprovedAutomatically() {
        let h = hub()
        h.ownConnectCode = { "own-code_1" }
        XCTAssertNil(h.selfConnectCode(URL(string: "https://hq.example.test/connect?code=strangers&device=x")!))
    }

    /// Nothing in flight: every Connect page is a person's decision.
    func testWithNoPairingInFlightNothingIsApproved() {
        let h = hub()
        XCTAssertNil(h.selfConnectCode(URL(string: "https://hq.example.test/connect?code=own-code_1")!))
        h.ownConnectCode = { "" }
        XCTAssertNil(h.selfConnectCode(URL(string: "https://hq.example.test/connect?code=")!))
    }

    /// Only the hub's own Connect page: the same code on another host, or on
    /// another path of the hub, is not it.
    func testOnlyTheHubsConnectPathCounts() {
        let h = hub()
        h.ownConnectCode = { "own-code_1" }
        XCTAssertNil(h.selfConnectCode(URL(string: "https://evil.example/connect?code=own-code_1")!))
        XCTAssertNil(h.selfConnectCode(URL(string: "https://hq.example.test/d/x?code=own-code_1")!))
    }
}
