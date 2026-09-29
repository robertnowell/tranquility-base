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

    /// The hub's sign-in, followed by the app (29 Sep, Robert: "the hub and
    /// tb are the same app"). Signing out here signs the app out; signing in
    /// here, on a Mac that is not connected, connects it. The window reads the
    /// hub's own session (Clerk) and reports only its changes.
    public var onSignedOut: () -> Void = {}
    public var onSignedIn: (_ user: String) -> Void = { _ in }
    /// Who the hub last said was signed in: nil until it has said anything,
    /// `.some(nil)` for nobody. Kept across page loads, so a sign-out that
    /// ends on the sign-in page is one change, and a first load that finds
    /// nobody signed in is not a sign-out.
    private(set) var hubUser: String??

    public private(set) var window: NSWindow?
    public private(set) var webView: WKWebView?
    private let base: () -> URL?
    private var titleWatch: NSKeyValueObservation?

    /// The marker `hq-open` reads before sending a page here rather than to
    /// the browser (hf-o8t.4). It holds this app's bundle path, so a marker
    /// left by an app since deleted is stale, and an app too old to know
    /// `tranquilitybase://hub` never wrote one: either way the page goes to
    /// the browser, which is always the fallback.
    public static let marker = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/hq/hub-window")

    /// Written at launch by an app that has the window.
    public static func announce(bundle: URL = Bundle.main.bundleURL, to file: URL = marker) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(bundle.path.utf8).write(to: file, options: .atomic)
    }

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
        config.userContentController.add(AuthMessages(self), name: "tbAuth")
        config.userContentController.addUserScript(WKUserScript(
            source: Self.authWatch, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        // Pinch and ⌘+/⌘- zoom, as in Safari (29 Sep: "can't zoom in with
        // touchpad"). A web view does not magnify unless asked to.
        web.allowsMagnification = true

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
        // An image the hub drew itself, opened in a window of its own. Only an
        // image: a data: page would be a page nobody served.
        if Self.isOwnImage(url) { return .allow }
        if clicked || scheme == "tranquilitybase" || scheme == "mailto" { openExternally(url) }
        return .cancel
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open: the hub opens in place, the rest in
        // the browser. A document's own external links are marked _blank by
        // the hub, so this is where they arrive.
        guard let url = action.request.url else { return nil }
        // "Open in New Window" on the hub, or on something the hub drew
        // itself (an image as a data: or blob: address): a second window of
        // the app, which WebKit fills. Handing a data: address to the system
        // put up Finder's "no application set to open the URL" (29 Sep).
        if isHub(url) || Self.isOwnImage(url) {
            return popup(configuration, title: url.lastPathComponent)
        }
        openExternally(url)
        return nil
    }

    /// A `data:image/…` address, or a `blob:` of the hub's own origin.
    static func isOwnImage(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "data": return url.absoluteString.lowercased().hasPrefix("data:image/")
        case "blob": return true
        default: return false
        }
    }

    /// Windows opened from the hub, kept until they close.
    private var popups: [NSWindow] = []

    private func popup(_ configuration: WKWebViewConfiguration, title: String) -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsMagnification = true
        let w = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Hub"
        w.isReleasedWhenClosed = false
        w.contentView = web
        w.cascadeTopLeft(from: window?.frame.origin ?? .zero)
        popups.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self, weak w] _ in
            MainActor.assumeIsolated { self?.popups.removeAll { $0 === w } }
        }
        if activates { w.makeKeyAndOrderFront(nil) }
        return web
    }

    /// Reports the hub's signed-in user (or null) once Clerk has loaded, and
    /// again whenever it changes. Main frame only: a document's sandboxed
    /// frame has no session to report.
    static let authWatch = """
    (function () {
      var last;
      function report() {
        var c = window.Clerk; if (!c || !c.loaded) return;
        var id = c.user ? c.user.id : null;
        if (id === last) return; last = id;
        window.webkit.messageHandlers.tbAuth.postMessage({ user: id });
      }
      var tries = 0, t = setInterval(function () {
        if (window.Clerk && window.Clerk.loaded) { clearInterval(t); report(); window.Clerk.addListener(report); }
        else if (++tries > 120) clearInterval(t);
      }, 250);
    })();
    """

    /// One report from the page. Only a change is acted on.
    func hubSaid(user: String?) {
        let before = hubUser
        hubUser = .some(user)
        switch (before, user) {
        case let (.some(.some(_)), nil):
            log("hub window: signed out in the hub; signing the app out")
            onSignedOut()
        case let (_, .some(id)) where before != .some(.some(id)):
            log("hub window: signed in to the hub")
            onSignedIn(id)
        default:
            break
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("hub window: web content process ended; reloading")
        webView.reload()
    }
}

/// The page's reports, held weakly: a content controller keeps its handlers
/// alive, and the window must not be kept alive by its own page.
private final class AuthMessages: NSObject, WKScriptMessageHandler {
    weak var window: HubWindow?
    init(_ window: HubWindow) { self.window = window }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let user = body["user"] as? String
        MainActor.assumeIsolated { window?.hubSaid(user: user) }
    }
}
