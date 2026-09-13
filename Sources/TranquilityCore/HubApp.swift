import Foundation

/// The hub app: where a report is read now.
///
/// Since 10 Sep 2026 the archive is mirrored into hq-app at the address in
/// `~/.claude/hq.json` under `app.base_url` (hq.tranquilitybase.dev). The
/// app announces a new page itself, in its own tab, so nothing here needs to
/// open a browser at a file any more: a door opens the page IN THE APP, and
/// a footer's "Open hub" reaches the agent there, from any device.
///
/// The one contract a client needs is `/open?session=<id>&slug=<slug>`: the
/// app mints its own ids on arrival, so the panel names a page by the two
/// things it already knows, the session directory and the file's slug. The
/// slug is the path under the agent directory with `.html` dropped and `/`
/// folded to `-`, which is exactly how the drainer names it on the way up
/// (hq-app `scripts/upload.mjs`); two spellings of one rule is how pages
/// get lost, so this one is pinned by a test.
///
/// When `app.base_url` is unset, every caller falls back to what it did
/// before: the local file. That is the whole configuration surface.
public enum HubApp {

    /// `app.base_url` from hq.json, or nil. Injectable so tests never read
    /// the machine's config.
    public static var baseURL: URL? { baseURL(config: configPath) }

    public static let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/hq.json")

    static func baseURL(config: URL) -> URL? {
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = obj["app"] as? [String: Any],
              let raw = app["base_url"] as? String,
              let url = URL(string: raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url
    }

    /// Write the app's address, and leave everything else exactly as it was.
    ///
    /// `hq.json` is not this app's file. The page-writing skills read it, the
    /// indexer reads it, and both put their own keys in it; the panel had
    /// never written it at all before the connect flow needed to. So this is a
    /// read, a merge and an atomic replace, not a serialisation of what this
    /// type happens to know about: every top-level key survives, and so does
    /// every key inside `app` other than the one being set. Clobbering a
    /// config file somebody else owns is the kind of thing that is discovered
    /// weeks later, by a tool that stopped finding its own setting.
    public static func setBaseURL(_ url: URL, config: URL = configPath) throws {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: config),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        var app = (obj["app"] as? [String: Any]) ?? [:]
        var address = url.absoluteString
        while address.hasSuffix("/") { address.removeLast() }
        app["base_url"] = address
        obj["app"] = app
        let data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: a half-written hq.json is a machine that has lost its hub
        // address AND whatever else the file held.
        try data.write(to: config, options: .atomic)
    }

    /// The page for `slug` in `session`, or the agent when `slug` is nil.
    public static func openURL(session: String, slug: String? = nil,
                               base: URL? = HubApp.baseURL) -> URL? {
        guard let base else { return nil }
        var parts = URLComponents(url: base.appendingPathComponent("open"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "session", value: session)]
        if let slug, !slug.isEmpty { items.append(URLQueryItem(name: "slug", value: slug)) }
        parts?.queryItems = items
        return parts?.url
    }

    /// The app's address for a report the panel has on disk, or nil when the
    /// path is not under an agent directory or the app is not configured.
    public static func openURL(forReportPath path: String, base: URL? = HubApp.baseURL) -> URL? {
        guard let (session, slug) = locate(path) else { return nil }
        return openURL(session: session, slug: slug, base: base)
    }

    /// `~/Documents/agents/<dir>/a/b.html` -> ("<dir>", "a-b"). The directory
    /// is the session (the full id since 06 Sep; the 8-character head on
    /// older pages, which the app accepts too). `index.html` at the top of a
    /// directory is the hub itself and names the agent, not a page.
    static func locate(_ path: String,
                       root: String = NSString(string: "~/Documents/agents").expandingTildeInPath)
        -> (session: String, slug: String?)? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let rel = String(path.dropFirst(prefix.count))
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let session = parts[0]
        let tail = parts.dropFirst().joined(separator: "/")
        if tail == "index.html" { return (session, nil) }
        guard tail.hasSuffix(".html") else { return nil }
        let slug = String(tail.dropLast(".html".count)).replacingOccurrences(of: "/", with: "-")
        return (session, slug)
    }
}
