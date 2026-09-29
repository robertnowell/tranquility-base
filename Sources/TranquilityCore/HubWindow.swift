import AppKit
import WebKit

/// The hub, in the app's own window: the web hub itself, not a copy of it.
///
/// Ruled 29 Sep 2026 (hf-o8t), twice. First, after a door sent the hub into a
/// Gmail draft's tab: "it makes a lot of sense for this to just be a fairly
/// simple Mac app." Then, on seeing a native sidebar built beside the web
/// one: "same as the web hub, one job, just render the same." So this window
/// loads hq-app, and everything in it (sidebar, Notes, teams, agent pages,
/// the document bar, Share, Discuss) is the web app's own, drawn by the same
/// engine Safari uses. There is one hub and it has one look.
///
/// Sign-in is the hub's own, an email code (hq-app .env.example), done once
/// in this window, and on a fresh install it is the same sign-in that
/// connects the Mac: pairing opens here (HubConnect), so one login is both. Clerk's cookie is first-party (clerk.hq.tranquilitybase.dev),
/// so it persists in the default data store across launches. A document is
/// still the web app's sandboxed frame, so its isolation is the browser's.
///
/// What the window adds is only what a browser tab cannot: every hub door
/// opens here, so a report never replaces a tab you were using.
@MainActor
public final class HubWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    public static let shared = HubWindow()
    /// Where failures are written; the app points it at app.log.
    public var log: (String) -> Void = { _ in }
    /// False in tests: an offscreen window must not take the screen.
    public var activates = true
    /// Where the sign-in lives. Tests use a throwaway store.
    public var dataStore: WKWebsiteDataStore = .default()
    /// Where a link off the hub goes. Injectable for tests.
    public var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }

    public private(set) var window: NSWindow?
    public private(set) var webView: WKWebView?
    private let base: () -> URL?
    private var titleWatch: NSKeyValueObservation?

    public init(base: @escaping () -> URL? = { HubApp.hub }) {
        self.base = base
    }

    /// Show a hub address here. False, and nothing shown, when `url` is not
    /// the hub: the caller keeps its old door for that.
    @discardableResult
    public func show(_ url: URL) -> Bool {
        guard isHub(url) else { return false }
        let web = make()
        web.load(URLRequest(url: url))
        present()
        return true
    }

    /// Open the window on the hub's home, or on whatever it last showed.
    public func showHub() {
        guard let home = base() else { return }
        let web = make()
        if web.url == nil { web.load(URLRequest(url: home)) }
        present()
    }

    /// The hub's host exactly, or one of its own subdomains (Clerk's sign-in
    /// API lives at clerk.<hub host>). Anything else is not the hub.
    func isHub(_ url: URL) -> Bool {
        guard let host = base()?.host?.lowercased(), let h = url.host?.lowercased(),
              url.scheme?.lowercased() == "https" else { return false }
        return h == host || h.hasSuffix("." + host)
    }

    private func present() {
        if activates { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
    }

    private func make() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        // The default store: the sign-in has to survive a relaunch.
        config.websiteDataStore = dataStore
        config.applicationNameForUserAgent = "TranquilityBase"
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Hub"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = web
        w.setFrameAutosaveName("HubWindow")
        if !w.setFrameUsingName("HubWindow") { w.center() }
        titleWatch = web.observe(\.title, options: [.new]) { [weak w] _, change in
            let title = (change.newValue ?? nil) ?? ""
            Task { @MainActor in w?.title = title.isEmpty ? "Hub" : title }
        }
        window = w
        webView = web
        return web
    }

    // MARK: - Navigation

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(route(action.request.url, mainFrame: action.targetFrame?.isMainFrame ?? true,
                              clicked: action.navigationType == .linkActivated))
    }

    /// The hub stays here; Discuss and the app's other links go to the app;
    /// anything else a person clicks goes to their browser. Frames inside a
    /// page (the document itself) are the web app's business.
    func route(_ url: URL?, mainFrame: Bool, clicked: Bool) -> WKNavigationActionPolicy {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if !mainFrame { return .allow }
        if isHub(url) || scheme == "about" { return .allow }
        if clicked || scheme == "tranquilitybase" || scheme == "mailto" { openExternally(url) }
        return .cancel
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open: the hub opens in place, the rest in
        // the browser. A document's own external links are marked _blank by
        // the hub, so this is where they arrive.
        if let url = action.request.url {
            if isHub(url) { webView.load(URLRequest(url: url)) } else { openExternally(url) }
        }
        return nil
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("hub window: web content process ended; reloading")
        webView.reload()
    }
}
