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
            seen[path] = Date(timeIntervalSince1970: ms / 1000)
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
