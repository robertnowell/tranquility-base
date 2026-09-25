import Foundation

/// Where a recorded page is READ, as opposed to where it is on disk.
///
/// Three places, in order. A page under the agents tree is read in the hub
/// app, at its `/open?session=&slug=` address. A page anywhere else is read at
/// the address it declares for itself: the hook records project pages on
/// purpose (21 Aug, a 168 KB brief in ~/Projects went unrecorded), and on
/// 24 Sep the newest such page was the website's own index.html, a
/// git-tracked file deployed on Vercel. The card said Open Report and opened
/// `file:///Users/.../tranquilitybase-site/index.html`, because the only
/// resolver knew the agents tree and fell back to the file.
///
/// Ruled 25 Sep: not a bare hub link ("I don't even know what I'm supposed to
/// look at here"), and not dropped from the record either. The door points at
/// the thing you should actually see, and a deployed page already says where
/// that is: `<link rel="canonical">`, `og:url`, or the `intranet:url` tag
/// share-as-page writes on every hosted page. Only a page that declares
/// nothing is still opened as a file, and the label says so.
public enum PageDestination: Equatable, Sendable {
    /// The hub app holds it.
    case hub(URL)
    /// The page's own live address, read off its head.
    case live(URL)
    /// Nothing better is known: the file itself.
    case file(String)

    public var url: URL {
        switch self {
        case .hub(let u), .live(let u): return u
        case .file(let path): return URL(fileURLWithPath: path)
        }
    }
}

public extension HubApp {
    /// The one resolver every door and every hub link goes through, so the
    /// card, the local hub and the mirror cannot disagree about where a page
    /// is read.
    static func destination(forReportPath path: String,
                            base: URL? = HubApp.baseURL) -> PageDestination {
        if let hub = openURL(forReportPath: path, base: base) { return .hub(hub) }
        if let live = ArtifactStore.liveAddress(of: path) { return .live(live) }
        return .file(path)
    }
}

public extension ArtifactStore {
    /// The address a page declares for itself, or nil.
    ///
    /// Read from the head only (16 KB), the same bound `declaredAgent` and
    /// the mirror's `meta` use: the tags live there and a page can be
    /// megabytes of embedded font. Three spellings, in the order a publisher
    /// would trust them: the archive's own `intranet:url` (written by
    /// share-as-page when it deploys), the page's `rel="canonical"`, then
    /// `og:url`. Either attribute order, because hand-written heads put
    /// `content` first about half the time. Only http(s): a canonical that
    /// points at a file or a relative path is not somewhere to send anyone.
    static func liveAddress(of path: String) -> URL? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384) else { return nil }
        return liveAddress(inHead: String(decoding: data, as: UTF8.self))
    }

    /// Pure, so the parsing is tested without a file.
    static func liveAddress(inHead head: String) -> URL? {
        let attr = "\"([^\"]*)\""
        let patterns = [
            "<meta\\s+name=\"intranet:url\"\\s+content=\(attr)",
            "<meta\\s+content=\(attr)\\s+name=\"intranet:url\"",
            "<link\\s+rel=\"canonical\"\\s+href=\(attr)",
            "<link\\s+href=\(attr)\\s+rel=\"canonical\"",
            "<meta\\s+property=\"og:url\"\\s+content=\(attr)",
            "<meta\\s+content=\(attr)\\s+property=\"og:url\"",
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
                  let r = Range(m.range(at: 1), in: head) else { continue }
            let value = head[r].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = url.host, !host.isEmpty else { continue }
            return url
        }
        return nil
    }
}
