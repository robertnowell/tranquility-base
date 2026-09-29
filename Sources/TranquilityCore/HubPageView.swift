import AppKit
import WebKit

/// The one view that shows a hub page. The only type in the app that touches
/// WebKit, so when the app can require macOS 26 its insides can become
/// SwiftUI's `WebPage` without anything around it changing: the two APIs map
/// one to one (data store, scheme handlers, navigation deciding, find, PDF).
///
/// What it enforces, each for a reason in the research record (hf-o8t):
///   * A private, non-persistent data store. Nothing a page stores survives
///     it, and no page can read another's storage. NetNewsWire does the same
///     for feed content.
///   * No script message handlers. A page has no bridge into the app.
///   * Hub addresses load here, through `HubDocumentLoader`. Anything else a
///     person clicks opens in their browser; anything a script tries to
///     navigate to on its own is dropped.
///   * A crashed page process reloads the page, once per load.
@MainActor
public final class HubPageView: NSView, WKNavigationDelegate, WKUIDelegate {
    public let webView: WKWebView
    private let loader: HubDocumentLoader
    private let base: URL?
    /// Where a clicked link that is not the hub goes. Injectable for tests.
    public var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Called with the page title whenever it changes.
    public var onTitle: ((String) -> Void)?
    private var titleWatch: NSKeyValueObservation?
    private var reloadedAfterCrash = false

    public init(base: URL? = HubApp.baseURL, loader: HubDocumentLoader? = nil) {
        self.base = base
        self.loader = loader ?? HubDocumentLoader(base: base)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self.loader, forURLScheme: HubPage.scheme)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.applicationNameForUserAgent = "TranquilityBase"
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        titleWatch = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            let title = view.title ?? ""
            Task { @MainActor in self?.onTitle?(title) }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Open a hub page by its hub address (`https://<hub>/d/<id>`,
    /// `/open?session=…&slug=…`) or its in-app address. Returns false, and
    /// loads nothing, for anything that is not the hub.
    @discardableResult
    public func open(_ url: URL) -> Bool {
        let target = url.scheme?.lowercased() == HubPage.scheme ? url : HubPage.inApp(url, base: base)
        guard let target, HubPage.onHub(target, base: base) != nil else { return false }
        reloadedAfterCrash = false
        webView.load(URLRequest(url: target))
        return true
    }

    /// The hub address of what is showing, for Share and Copy Link.
    public var hubURL: URL? { webView.url.flatMap { HubPage.onHub($0, base: base) } }

    // MARK: - Navigation

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        preferences: WKWebpagePreferences,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        decisionHandler(route(action), preferences)
    }

    /// Where a navigation goes. Split out so the rule reads in one place.
    func route(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if scheme == HubPage.scheme { return mainFrame ? .allow : .cancel }
        if scheme == "about" || scheme == "data" { return mainFrame ? .cancel : .allow }
        if mainFrame {
            // A hub address written absolutely: load it here instead.
            if let inApp = HubPage.inApp(url, base: base) {
                webView.load(URLRequest(url: inApp))
            } else if action.navigationType == .linkActivated {
                openExternally(url)
            }
            // Anything else a script navigates to on its own goes nowhere.
            return .cancel
        }
        // An embedded frame on the open web (a video, a map): it is the page's
        // own content, isolated by WebKit like any cross-origin frame.
        return scheme == "https" ? .allow : .cancel
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open. The hub's own link script marks
        // external links _blank; only a click may send one to the browser.
        if let url = action.request.url {
            if let inApp = url.scheme?.lowercased() == HubPage.scheme ? url : HubPage.inApp(url, base: base) {
                webView.load(URLRequest(url: inApp))
            } else if action.navigationType == .linkActivated || action.navigationType == .other,
                      url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" || url.scheme == "mailto" {
                openExternally(url)
            }
        }
        return nil
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // No reason is ever given. Reload once; a page that kills its process
        // twice in a row stays down rather than looping.
        guard !reloadedAfterCrash else { return }
        reloadedAfterCrash = true
        webView.reload()
    }

    // MARK: - Find and print

    /// Find in the page. WKWebView's own find; NSTextFinder does not work
    /// with it on the Mac.
    public func find(_ text: String, backwards: Bool = false) async -> Bool {
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        return (try? await webView.find(text, configuration: config).matchFound) ?? false
    }

    /// Print the page. The frame line is the workaround Apple's DTS gave for
    /// a crash on macOS 26: WebKit's printing view otherwise has a zero frame.
    public func printPage(in window: NSWindow) {
        let op = webView.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = webView.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}
