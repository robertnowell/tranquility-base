import Foundation
import WebKit

/// Hub pages, loaded in the app's own window rather than in a browser.
///
/// A page is addressed as `hub://<hub host>/<path>`: the hub's own address
/// with the scheme swapped, and nothing else. So the relative links the hub
/// already writes into a document (`/open?session=…&slug=…`) resolve to the
/// right in-app address with no rewriting, and turning one back into the
/// address to fetch is the same swap in reverse.
///
/// Ruled 29 Sep 2026 (hf-o8t): native window, WebKit for the page, scripts on
/// with the network closed. Research record:
/// agents/04b6707d…/2026-09-29-hub-mac-client-architecture/report.md
public enum HubPage {
    public static let scheme = "hub"

    /// The policy every page is served under.
    ///
    /// `sandbox` without `allow-same-origin` gives the page an opaque origin,
    /// the same isolation the web app's frame has. `connect-src 'none'` is the
    /// Mac's addition: a page's script cannot fetch, post or open a socket.
    /// Images, fonts, stylesheets and CDN scripts still load, which is what
    /// the 18 pages of 1,531 that reach outside themselves use them for.
    public static let policy =
        "sandbox allow-scripts allow-forms allow-popups allow-modals; " +
        "connect-src 'none'; frame-ancestors 'none'"

    /// The in-app address for a hub address, or nil if `url` is not the hub.
    /// Host compared exactly, as HubRead does: the token follows this mapping.
    public static func inApp(_ url: URL, base: URL?) -> URL? {
        guard let base, let host = base.host?.lowercased(),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == host,
              url.user == nil, url.password == nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return nil }
        parts.scheme = scheme
        parts.port = nil
        return parts.url
    }

    /// The hub address an in-app address stands for.
    public static func onHub(_ url: URL, base: URL?) -> URL? {
        guard let base, let host = base.host?.lowercased(),
              url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return nil }
        parts.scheme = "https"
        parts.port = base.port
        return parts.url
    }

    /// Whether the loader may answer this request at all.
    ///
    /// Only a top-level document load: the request IS the page being opened.
    /// Measured 29 Sep with a probe: a loader that answers anything on its
    /// scheme hands a page's own script every other document, because it is
    /// the loader, not the page, that holds the token. A script's fetch, an
    /// image or an iframe on `hub:` all carry the page as their main document
    /// and are refused here.
    public static func mayServe(_ request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme?.lowercased() == scheme else { return false }
        return request.mainDocumentURL == url
    }

    /// Whether a landing address is a document. Anything else a redirect can
    /// end at (an agent's page, a sign-in) is the web app, not a page.
    static func isDocument(_ landed: URL) -> Bool {
        let parts = landed.pathComponents
        return parts.count == 4 && parts[1] == "d" && parts[3] == "raw"
    }

    /// What the window shows when there is no document to show.
    static func notice(_ title: String, _ detail: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        return """
        <!doctype html><meta charset="utf-8"><title>\(esc(title))</title>
        <style>body{font:15px/1.5 -apple-system,system-ui;margin:18vh auto;max-width:34em;padding:0 24px;color:#57534c}
        h1{font-size:22px;color:#141312;margin:0 0 8px}@media(prefers-color-scheme:dark){body{background:#1c1b19;color:#b4afa6}h1{color:#f2efe8}}</style>
        <h1>\(esc(title))</h1><p>\(esc(detail))</p>
        """
    }
}

/// Serves `hub://` pages to a web view, holding the credential itself.
///
/// The page never sees the token: the loader fetches with it and hands the
/// web view bytes. Every answer carries `HubPage.policy`. Redirects are
/// followed inside `HubRead.fetchLanding`, which re-checks the host on every
/// hop, so a redirect off the hub cannot take the token with it.
@MainActor
public final class HubDocumentLoader: NSObject, WKURLSchemeHandler {
    public typealias Fetch = @Sendable (String) async -> Result<(html: String, landed: URL), HubRead.Failure>

    private let base: URL?
    private let fetch: Fetch
    /// Tasks WebKit has not yet stopped. Answering a stopped task raises an
    /// Objective-C exception, so every late answer checks this first.
    private var live = Set<ObjectIdentifier>()

    public init(base: URL? = HubApp.baseURL, fetch: Fetch? = nil) {
        self.base = base
        self.fetch = fetch ?? { arg in await HubRead.fetchLanding(arg) }
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard HubPage.mayServe(task.request), let url = task.request.url,
              let https = HubPage.onHub(url, base: base) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let id = ObjectIdentifier(task)
        live.insert(id)
        let fetch = self.fetch
        Task { @MainActor [weak self] in
            let result = await fetch(https.absoluteString)
            guard let self, self.live.remove(id) != nil else { return }
            let html: String
            switch result {
            case .success(let got) where HubPage.isDocument(got.landed):
                html = got.html
            case .success:
                html = HubPage.notice("Not on the hub yet",
                                      "This page has not arrived from the Mac that wrote it. It usually does within a minute.")
            case .failure(.notConnected):
                html = HubPage.notice("This Mac is not connected to a hub",
                                      "Connect it from the Tranquility Base menu, then open the page again.")
            case .failure(.http(404)):
                html = HubPage.notice("No such page", "The hub has no page at this address.")
            case .failure(let why):
                html = HubPage.notice("The hub did not answer", "\(why)")
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": HubPage.policy,
                "Cache-Control": "no-store",
            ])!
            task.didReceive(response)
            task.didReceive(Data(html.utf8))
            task.didFinish()
        }
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }
}
