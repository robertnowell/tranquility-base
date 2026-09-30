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
    /// A one-time sign-in address for this window, from the app, when the
    /// Mac is connected; nil when it is not (30 Sep, Robert: one account, so
    /// a connected Mac never shows the hub's sign-in page). Given the hub
    /// path the window should land on. See HubWebSession.
    public var silentSignIn: (_ next: String) async -> URL? = { _ in nil }
    /// When the window last asked, so a ticket that fails is not retried in a
    /// loop: once a minute at most.
    private var lastSilentAttempt: Date?
    /// The pairing code THIS app invented for the Connect it is waiting on,
    /// or nil. Set by the app; read when the hub's Connect page loads here.
    public var ownConnectCode: () -> String? = { nil }
    /// Codes this window has already pressed Connect for, so a reload or a
    /// back-navigation never approves twice.
    private var selfConnected: Set<String> = []
    /// Who the hub last said was signed in: nil until it has said anything,
    /// `.some(nil)` for nobody. Kept across page loads, so a sign-out that
    /// ends on the sign-in page is one change, and a first load that finds
    /// nobody signed in is not a sign-out.
    private(set) var hubUser: String??

    public private(set) var window: NSWindow?
    /// The last address this window was asked to show.
    public private(set) var lastShown: URL?
    public private(set) var webView: WKWebView?
    private let base: () -> URL?
    private var titleWatch: NSKeyValueObservation?
    /// ⌘F's bar, and the constraint that collapses it to nothing when closed.
    public private(set) var findBar: HubFindBar?
    private var findHeight: NSLayoutConstraint?
    /// The document being printed, held until its page has loaded.
    private var printing: PrintLoader?

    public init(base: @escaping () -> URL? = { HubApp.hub }) {
        self.base = base
    }

    /// Show a hub address here. False, and nothing shown, when `url` is not
    /// the hub: the caller keeps its old door for that.
    @discardableResult
    public func show(_ url: URL) -> Bool {
        guard isHub(url) else {
            log("hub window: \(Self.describe(url)) is not the hub; left to the caller")
            return false
        }
        log("hub window: showing \(Self.describe(url))")
        let web = make()
        lastShown = url
        web.load(URLRequest(url: url))
        present()
        return true
    }

    /// A page an agent reported on its own, not one the person asked for.
    /// Ruled 29 Sep (Robert): with the Hub window open, do nothing, neither
    /// focus it nor move it off the page being read; the toast and the
    /// sidebar's live order already say a report arrived. With no window,
    /// open it on the report. True when handled here (including left alone);
    /// false for an address that is not the hub, which the caller sends on.
    @discardableResult
    public func offer(_ url: URL) -> Bool {
        guard isHub(url) else { return false }
        if let window, window.isVisible {
            log("hub window: open already; a report \(Self.describe(url)) arrived and was left for the sidebar")
            return true
        }
        return show(url)
    }

    /// Open the window on the hub's home, or on whatever it last showed.
    public func showHub() {
        guard let home = base() else { log("hub window: no hub address; nothing to show"); return }
        let web = make()
        log("hub window: opened\(web.url == nil ? " on the hub's home" : ", on \(Self.describe(web.url))")")
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
        w.contentView = frame(around: web)
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

    // MARK: - Find and print

    /// The page, with ⌘F's bar above it, collapsed until asked for.
    private func frame(around web: WKWebView) -> NSView {
        let container = NSView()
        let bar = HubFindBar(web: web)
        bar.onClose = { [weak self] in self?.closeFind() }
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        container.addSubview(web)
        let height = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            height,
            web.topAnchor.constraint(equalTo: bar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        bar.isHidden = true
        findBar = bar
        findHeight = height
        return container
    }

    /// ⌘F. The app's hidden main menu sends it to the key window, whose
    /// delegate this is, so it reaches here only when the Hub window is key.
    @objc public func hubFind(_ sender: Any?) {
        guard let bar = findBar else { return }
        bar.isHidden = false
        findHeight?.constant = 38
        window?.makeFirstResponder(bar.field)
    }

    @objc public func hubFindNext(_ sender: Any?) { Task { await findBar?.find(backwards: false) } }
    @objc public func hubFindPrevious(_ sender: Any?) { Task { await findBar?.find(backwards: true) } }

    func closeFind() {
        findBar?.isHidden = true
        findHeight?.constant = 0
        if let web = webView { window?.makeFirstResponder(web) }
    }

    /// ⌘P. On a document, the document alone: the raw page loaded with the
    /// window's own sign-in, without the hub's bar and sidebar around it.
    /// Anywhere else, the page as it is.
    @objc public func hubPrint(_ sender: Any?) {
        guard let web = webView, let window else { return }
        guard let current = web.url, let raw = Self.rawAddress(for: current) else {
            Self.runPrint(web, over: window)
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let sheet = WKWebView(frame: web.bounds, configuration: config)
        printing = PrintLoader(sheet) { [weak self, weak window] loaded in
            if let window { Self.runPrint(loaded, over: window) }
            self?.printing = nil
        }
        sheet.load(URLRequest(url: raw))
    }

    /// `/d/<id>` → `/d/<id>/raw`, the document's own bytes; nil for any
    /// other page.
    static func rawAddress(for url: URL) -> URL? {
        let parts = url.pathComponents
        guard parts.count == 3, parts[1] == "d", parts[2].count >= 32 else { return nil }
        return url.appendingPathComponent("raw")
    }

    /// The frame line is Apple DTS's workaround for a macOS 26 crash in
    /// WebKit printing (forum 811901): its printing view otherwise has a
    /// zero frame. Run modally, as that thread says.
    static func runPrint(_ web: WKWebView, over window: NSWindow) {
        let op = web.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = web.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: - Navigation

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        let policy = route(url, mainFrame: mainFrame, clicked: action.navigationType == .linkActivated)
        if mainFrame, policy == .cancel {
            log("hub window: not loading \(Self.describe(url)) here (\(isHub(url ?? URL(string: "about:x")!) ? "hub" : "off the hub"))")
        }
        decisionHandler(policy)
    }

    // What the window did, for app.log (29 Sep: a blank window and nothing
    // anywhere saying why). Addresses are cut to scheme, host and path: a
    // sign-in link carries a one-time ticket in its query.
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log("hub window: loading \(Self.describe(webView.url))")
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("hub window: loaded \(Self.describe(webView.url))")
        if let code = selfConnectCode(webView.url) { pressConnect(code, in: webView) }
    }

    // MARK: - Connecting this Mac, without asking the person to compare

    /// The code to approve without a person comparing phrases, or nil.
    ///
    /// The phrase on the hub's Connect page exists for one attack: a stranger
    /// mails a signed-in person a /connect link carrying THEIR code, and one
    /// click pairs the stranger's computer (HubPairing's design note, RFC 8628
    /// section 5.4). The comparison proves the code on the page is the one on
    /// the Mac in front of you. When this app opened that page in its own
    /// window with a code it invented a moment ago, it can make the comparison
    /// itself; asking the person to do it is the second code Robert met on
    /// 29 Sep ("it's confirming the same app").
    ///
    /// So: a Connect page on the hub whose code is the one this app is waiting
    /// on, and not already pressed. A link anybody sent carries some other
    /// code and gets the phrase screen, as before. Never a flag in the URL: a
    /// flag can be copied into a stranger's link; this app's own in-memory
    /// code cannot.
    func selfConnectCode(_ url: URL?) -> String? {
        guard let url, isHub(url), url.path == "/connect",
              let own = ownConnectCode(), !own.isEmpty,
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value,
              code == own, !selfConnected.contains(code) else { return nil }
        return code
    }

    /// Press the page's own Connect, only if the form on it carries this code.
    /// The page decides what approving means; the app only stands in for the
    /// person's click, and checks the form it is clicking one more time.
    private func pressConnect(_ code: String, in webView: WKWebView) {
        selfConnected.insert(code)
        let literal = (try? String(data: JSONSerialization.data(withJSONObject: [code]), encoding: .utf8)) ?? "[]"
        let js = """
        (function (c) {
          var i = document.querySelector('form input[name="code"]');
          if (!i || i.value !== c) return 'no-form';
          var b = i.form.querySelector('button[type="submit"]');
          if (!b) return 'no-button';
          b.click(); return 'pressed';
        })(\(literal)[0])
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            let said = (result as? String) ?? error?.localizedDescription ?? "nothing"
            MainActor.assumeIsolated { self?.log("hub window: this Mac's own Connect page, \(said)") }
        }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("hub window: could not load \(Self.describe(webView.url)): \(error.localizedDescription)")
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("hub window: load failed \(Self.describe(webView.url)): \(error.localizedDescription)")
    }

    static func describe(_ url: URL?) -> String {
        guard let url else { return "nothing" }
        if url.scheme?.lowercased() == "data" { return "an inline \(url.absoluteString.prefix(20))…" }
        return "\(url.scheme ?? "?")://\(url.host ?? "")\(url.path)"
    }

    /// The hub stays here; Discuss and the app's other links go to the app;
    /// anything else a person clicks goes to their browser. Frames inside a
    /// page (the document itself) are the web app's business.
    func route(_ url: URL?, mainFrame: Bool, clicked: Bool) -> WKNavigationActionPolicy {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if !mainFrame {
            // A document is a frame inside the hub's page, so a link clicked in
            // it navigates that frame, not the window. Left to .allow, an
            // outside site opened INSIDE the Hub window (29 Sep, hf-o8t.11).
            // A click off the hub goes to the browser; everything else a frame
            // loads (the document itself, about:, an embedded video) is the
            // page's own content and stays.
            if clicked, !isHub(url), scheme == "https" || scheme == "http" || scheme == "mailto" {
                openExternally(url)
                log("hub window: a link in a document went to the browser: \(Self.describe(url))")
                return .cancel
            }
            return .allow
        }
        if isHub(url) || scheme == "about" { return .allow }
        if clicked || scheme == "tranquilitybase" || scheme == "mailto" { openExternally(url) }
        return .cancel
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open: the hub opens in place, the rest in
        // the browser. A document's own external links are marked _blank by
        // the hub, so this is where they arrive.
        guard let url = action.request.url else { return nil }
        if isHub(url) {
            webView.load(URLRequest(url: url))
        } else if let image = Self.inlineImage(url) {
            // "Open Image in New Window" on an image the page carries inline.
            // Given to the system, a data: address put up Finder's "no
            // application set to open the URL"; given to a new web view, it
            // is a top-level data: navigation, which WebKit refuses, and the
            // window stayed blank (both 29 Sep). So the app shows it itself.
            showImage(image)
        } else {
            log("hub window: opening \(Self.describe(url)) in the browser")
            openExternally(url)
        }
        return nil
    }

    /// The picture in a `data:image/…;base64,` address, or nil.
    static func inlineImage(_ url: URL) -> NSImage? {
        let raw = url.absoluteString
        guard raw.lowercased().hasPrefix("data:image/"), let comma = raw.firstIndex(of: ","),
              raw[..<comma].lowercased().hasSuffix(";base64"),
              let data = Data(base64Encoded: String(raw[raw.index(after: comma)...]).removingPercentEncoding ?? "")
        else { return nil }
        return NSImage(data: data)
    }

    /// Windows opened from the hub, kept until they close.
    private var popups: [NSWindow] = []

    private func showImage(_ image: NSImage) {
        let view = NSImageView(image: image)
        view.frame = NSRect(origin: .zero, size: image.size)
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true   // pinch, as in Preview
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 8
        let size = NSSize(width: min(image.size.width, 1400), height: min(image.size.height, 1000))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = window?.title ?? "Hub"
        w.isReleasedWhenClosed = false
        w.contentView = scroll
        w.cascadeTopLeft(from: window?.frame.origin ?? .zero)
        popups.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self, weak w] _ in
            MainActor.assumeIsolated { self?.popups.removeAll { $0 === w } }
        }
        log("hub window: showing an image \(Int(image.size.width))×\(Int(image.size.height)) in its own window")
        if activates { w.makeKeyAndOrderFront(nil) }
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
        case (_, nil):
            // Nobody signed in, and nobody just signed out: a window whose web
            // store is empty on a Mac that may well be connected. Sign it in
            // as the Mac's account rather than show a sign-in page.
            signInSilently()
        case let (_, .some(id)) where before != .some(.some(id)):
            log("hub window: signed in to the hub")
            onSignedIn(id)
        default:
            break
        }
    }

    private func signInSilently() {
        if let last = lastSilentAttempt, Date().timeIntervalSince(last) < 60 { return }
        lastSilentAttempt = Date()
        let next = HubWebSession.landing(from: webView?.url)
        Task { @MainActor [weak self] in
            guard let self, let url = await self.silentSignIn(next) else { return }
            guard self.isHub(url) else { self.log("hub window: a sign-in address off the hub was refused"); return }
            self.log("hub window: nobody signed in here; signing in as this Mac's account")
            self.webView?.load(URLRequest(url: url))
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


/// Loads one page off screen and hands it over once it has finished.
@MainActor
final class PrintLoader: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let done: (WKWebView) -> Void
    init(_ web: WKWebView, done: @escaping (WKWebView) -> Void) {
        self.web = web
        self.done = done
        super.init()
        web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done(webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done(webView) }
}
