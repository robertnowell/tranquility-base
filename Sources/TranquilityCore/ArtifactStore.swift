import Foundation

/// The most recent page a session made, so the panel can offer to open it.
///
/// This deliberately does NOT go through the spool and the events table. Two
/// reasons, and the second is the one that matters:
///
/// 1. There is nothing to announce. An artifact is not a turn; it has no
///    summary, no callsign line, no place in the waiting queue. Putting it in
///    `events` would mean teaching every query that reads that table to exclude
///    a row type it never wants.
/// 2. `SpoolRecord.toEvent()` maps an unknown `hookEvent` to `.stop`. A new
///    event kind written by a new hook and read by an older build would
///    therefore be filed as a finished turn and SPOKEN — the user hearing a
///    summary of a file write, from a hook they installed for a button. A
///    separate file cannot do that to anyone.
///
/// So: one small file per agent, appended to. It began as a single path
/// replaced by rename, which answered the panel button ("open the newest page")
/// and nothing else — and the hub then needed the LIST. An append-only log of
/// `epochMs<TAB>path` answers both: the last line is the newest page, the whole
/// file is the agent's body of work. A single small write with O_APPEND is
/// atomic, so concurrent turns cannot interleave, and a line without a tab is
/// read as a bare path so records written by the older hook still resolve.
public enum ArtifactStore {

    public static func directory(root: String) -> String {
        (root as NSString).appendingPathComponent("artifacts")
    }

    /// A session id is a UUID from the harness, but it arrives here from a hook
    /// payload and ends up in a path, so it is checked rather than trusted:
    /// anything but hex and dashes could escape the directory.
    static func isPlausibleSession(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    @discardableResult
    public static func record(_ path: String, session: String, root: String,
                              at: Date = Date()) -> Bool {
        guard isPlausibleSession(session), path.hasPrefix("/") else { return false }
        let dir = directory(root: root)
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let target = (dir as NSString).appendingPathComponent(session)
        let line = "\(Int(at.timeIntervalSince1970 * 1000))\t\(path)\n"
        guard let data = line.data(using: .utf8) else { return false }
        let fd = open(target, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
    }

    /// One recorded page.
    public struct Page: Sendable, Equatable {
        public let path: String
        public let at: Date
        public var name: String { (path as NSString).lastPathComponent }
        /// The directory a page lives in usually names it better than
        /// "index.html" does.
        public var label: String {
            let dir = (path as NSString).deletingLastPathComponent
            let leaf = (dir as NSString).lastPathComponent
            return name == "index.html" && !leaf.isEmpty ? leaf : name
        }
    }

    /// Everything this agent has made, oldest first, deduplicated by path with
    /// the FIRST write kept — a page rewritten eight times in one turn is one
    /// page, and the moment it first appeared is the moment worth showing.
    public static func history(for session: String, root: String,
                               exists: (String) -> Bool = {
                                   FileManager.default.fileExists(atPath: $0)
                               }) -> [Page] {
        guard isPlausibleSession(session) else { return [] }
        let target = (directory(root: root) as NSString)
            .appendingPathComponent(session)
        guard let text = try? String(contentsOfFile: target, encoding: .utf8)
        else { return [] }
        var seen: [String: Date] = [:]
        var order: [String] = []
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: "\t", maxSplits: 1)
            let path = String(parts.count == 2 ? parts[1] : parts[0])
            guard path.hasPrefix("/"), seen[path] == nil else { continue }
            let ms = parts.count == 2 ? Double(parts[0]) ?? 0 : 0
            // A line with no stamp (the hook wrote path-only lines for a
            // while) is not "31 Dec 1969" — epoch zero rendered as a date is
            // the page claiming knowledge it does not have. The file's own
            // mtime is the honest substitute; only when the file cannot answer
            // either does the page get no date at all.
            seen[path] = ms > 0 ? Date(timeIntervalSince1970: ms / 1000)
                : (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                    as? Date ?? .distantPast
            order.append(path)
        }
        return order.filter(exists).map { Page(path: $0, at: seen[$0] ?? .distantPast) }
    }

    /// The page to offer, or nil — and nil is the common case, so every caller
    /// must render without it.
    ///
    /// The existence check is not defensive tidiness: pages get regenerated,
    /// moved into HQ, and deleted, and a button that opens a file that is gone
    /// is worse than no button, because it spends a click to say nothing.
    public static func latest(for session: String, root: String,
                              exists: (String) -> Bool = {
                                  FileManager.default.fileExists(atPath: $0)
                              }) -> String? {
        guard isPlausibleSession(session) else { return nil }
        let target = (directory(root: root) as NSString)
            .appendingPathComponent(session)
        guard let contents = try? String(contentsOfFile: target, encoding: .utf8)
        else { return nil }
        // The newest page is the last line that still names something on disk —
        // not simply the last line, because the file a turn wrote can be moved
        // or deleted before anyone clicks.
        for raw in contents.split(separator: "\n").reversed() {
            let parts = raw.split(separator: "\t", maxSplits: 1)
            let path = String(parts.count == 2 ? parts[1] : parts[0])
            if path.hasPrefix("/"), exists(path) { return path }
        }
        return nil
    }
}

public extension ArtifactStore {

    /// Recover an agent's pages from its transcript.
    ///
    /// The hook only started recording when it was installed, so every agent
    /// that ran before then shows no pages at all — which is worse than wrong,
    /// because a hub that says "0 pages" about an agent with six of them
    /// teaches the reader not to trust the number. The transcript has been
    /// recording the same fact all along: every Write of an .html file, with a
    /// timestamp. This reads it once and fills the log in.
    ///
    /// Deliberately additive and idempotent: it appends only paths the log does
    /// not already carry, so running it twice is a no-op and a live agent's
    /// newer records are never disturbed.
    @discardableResult
    static func backfill(session: String, transcriptPath: String, root: String) -> Int {
        guard isPlausibleSession(session),
              let handle = FileHandle(forReadingAtPath: transcriptPath),
              let data = try? handle.readToEnd() else { return 0 }
        try? handle.close()
        let known = Set(history(for: session, root: root, exists: { _ in true })
            .map(\.path))
        var added = 0
        var seen = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.count > 2,
                  let text = String(data: Data(line), encoding: .utf8),
                  text.contains(".html"), text.contains("tool_use"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any] else { continue }
            let stamp = (object["timestamp"] as? String).flatMap(Self.iso8601) ?? Date()
            let message = object["message"] as? [String: Any]
            for block in (message?["content"] as? [[String: Any]]) ?? [] {
                guard block["type"] as? String == "tool_use",
                      let tool = block["name"] as? String,
                      ["Write", "Edit", "NotebookEdit"].contains(tool),
                      let input = block["input"] as? [String: Any],
                      let path = input["file_path"] as? String,
                      path.hasSuffix(".html"), path.hasPrefix("/"),
                      !known.contains(path), !seen.contains(path) else { continue }
                seen.insert(path)
                if record(path, session: session, root: root, at: stamp) { added += 1 }
            }
        }
        return added
    }

    /// Transcript stamps are UTC. Parsing them as local time put every page
    /// seven hours into the future during the prototype, which silently emptied
    /// the list it was meant to fill.
    private static func iso8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: text)
        }()
    }
}

public extension ArtifactStore {

    /// What a page is actually called, and what it is about.
    ///
    /// A directory slug — "vd-grid-mock" — is a filename, not a title. The page
    /// itself has said what it is all along, in the same places every reader
    /// tool looks. The precedence below is Mozilla Readability's, trimmed to
    /// what a local file can offer: `og:title`, then `<title>` with any trailing
    /// " — Site" segment removed, then the first `<h1>`.
    ///
    /// Readability's most useful move is its fallback CONDITION rather than its
    /// order: a title under 15 or over 150 characters is treated as unusable and
    /// the `<h1>` is preferred instead. That single rule is what rescues pages
    /// whose title is a bare slug or an entire sentence.
    struct DocumentSummary: Sendable, Equatable {
        public let title: String?
        /// The opening line, for a hover card. Wikipedia's Page Previews show
        /// the first non-empty paragraph and clip it visually rather than at a
        /// character count; this keeps the text short enough that clipping is
        /// rarely needed.
        public let blurb: String?
    }

    /// Only the head and the opening of the body are read — a rendered page can
    /// be a megabyte of inlined CSS, and the answer is always near the top.
    static func summarize(path: String, limit: Int = 24_000) -> DocumentSummary {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return DocumentSummary(title: nil, blurb: nil)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        guard let html = String(data: data, encoding: .utf8) else {
            return DocumentSummary(title: nil, blurb: nil)
        }
        let og = firstMatch(in: html,
            #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#)
        let titleTag = firstMatch(in: html, #"(?s)<title[^>]*>(.*?)</title>"#)
            .map(trimSiteSuffix)
        let heading = firstMatch(in: html, #"(?s)<h1[^>]*>(.*?)</h1>"#).map(stripTags)
        let candidate = og ?? titleTag
        let title: String?
        if let candidate, candidate.count >= 15, candidate.count <= 150 {
            title = candidate
        } else {
            title = heading ?? candidate
        }
        let description = firstMatch(in: html,
            #"<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']"#)
        let paragraph = firstMatch(in: html, #"(?s)<p[^>]*>(.*?)</p>"#).map(stripTags)
        let blurb = (description ?? paragraph).map { text -> String in
            text.count > 220 ? String(text.prefix(217)) + "…" : text
        }
        return DocumentSummary(title: title?.isEmpty == false ? title : nil,
                               blurb: blurb?.isEmpty == false ? blurb : nil)
    }

    /// "Plan — Tranquility Base" is one title with a site name stapled on. The
    /// separators are Readability's list.
    private static func trimSiteSuffix(_ text: String) -> String {
        let cleaned = stripTags(text)
        for separator in [" — ", " – ", " | ", " · ", " \\ ", " / ", " » ", " > "] {
            if let range = cleaned.range(of: separator, options: .backwards) {
                let head = String(cleaned[..<range.lowerBound])
                // Only when what remains is still a title rather than a word.
                if head.count >= 15 { return head }
            }
        }
        return cleaned
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&middot;", with: "·")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(in text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
