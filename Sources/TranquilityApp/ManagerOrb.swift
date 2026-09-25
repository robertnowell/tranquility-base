import AppKit
import WebKit

/// The manager's face on the grid: the thinking orb.
///
/// The orb is `thinking-orbs` (Jakub Antalik, MIT), a plain 2D-canvas engine
/// with nine hand-tuned states, vendored under Resources/Orb and drawn in a
/// transparent web view sized to one grid cell. Nothing here is interactive;
/// it is a lamp with a line of text under it. States are mapped from the
/// manager's events: breathing when idle, listening when a turn was heard,
/// solving when addressed, composing while the manager speaks, connecting
/// while a session holds the stage.
@MainActor
final class ManagerOrbView: NSView {
    static let height: CGFloat = 150
    private let web: WKWebView
    private var ready = false
    private var pending: (String, String, String)?

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        web.translatesAutoresizingMaskIntoConstraints = false
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        if let page = Self.pageURL() {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            Permissions.log("orb: Resources/Orb/orb.html not found; the manager has no face")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// One of the engine's states, and the line under the orb.
    func set(_ state: String, line: String, mood: String = "") {
        guard ready else { pending = (state, line, mood); return }
        let js = "window.setOrb(\(Self.quote(state)), \(Self.quote(line)), \(Self.quote(mood)))"
        web.evaluateJavaScript(js) { _, error in
            if let error { Permissions.log("orb: \(error.localizedDescription)") }
        }
    }

    private static func quote(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    /// Bundled first (bundle.sh copies Resources/Orb), the repo copy in
    /// development, the same two-step lookup Earcons uses for its sounds.
    private static func pageURL() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Orb/orb.html"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Orb/orb.html")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }
}

extension ManagerOrbView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        if let (state, line, mood) = pending { pending = nil; set(state, line: line, mood: mood) }
    }
}
