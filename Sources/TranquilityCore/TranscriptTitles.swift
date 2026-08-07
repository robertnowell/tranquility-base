import Foundation

/// The terminal tab's string for a Claude Code session.
///
/// Claude Code titles the tab from the transcript's `ai-title` records, and an
/// explicitly named session has its name mirrored into the same record type —
/// verified 05 Aug against every live session: each named session's last
/// ai-title equals its name verbatim. So the LAST ai-title line IS the tab,
/// named or unnamed alike. `claude agents --json`'s `name` is NOT: for unnamed
/// sessions it is a derived slug ("robertnowell-90", `nameSource: "derived"` in
/// ~/.claude/sessions) that the tab never displays — showing it made the grid
/// and the terminal disagree about the same session.
///
/// Transcripts are append-only, so each lookup scans only bytes added since the
/// last one. The first lookup pays one full scan (titles can be minted early
/// and never again, so tail-capping would miss them — mine sits at line 25 of
/// a megabyte file). The cursor only ever advances to the end of the last
/// COMPLETE line, so a partially-flushed record is re-read next tick instead of
/// being split. A shrunken file resets the cursor.
public final class TranscriptTitles: @unchecked Sendable {
    public static let shared = TranscriptTitles()

    private struct Cursor {
        var offset: UInt64
        var title: String?
    }

    private let lock = NSLock()
    private var cursors: [String: Cursor] = [:]
    private static let marker = Data("\"type\":\"ai-title\"".utf8)
    private static let newline = UInt8(ascii: "\n")

    public init() {}

    /// ~/.claude/projects/<slug>/<sessionId>.jsonl — Claude Code slugs the cwd
    /// by replacing every non-alphanumeric character with "-"
    /// ("/Users/x/a.b" → "-Users-x-a-b").
    public static func defaultPath(cwd: String, sessionId: String) -> String {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/projects/\(slug)/\(sessionId).jsonl"
    }

    /// The latest `aiTitle` in the transcript, or nil while none exists yet
    /// (a brand-new session) or the file cannot be read.
    public func latestTitle(transcriptPath: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        var cursor = cursors[transcriptPath] ?? Cursor(offset: 0, title: nil)
        if cursor.offset > size { cursor = Cursor(offset: 0, title: nil) }
        guard cursor.offset < size else { return cursor.title }
        try? handle.seek(toOffset: cursor.offset)

        // Chunked forward scan of the new bytes. `pending` holds the partial
        // line straddling a chunk boundary; whatever partial line remains at
        // EOF is NOT consumed — the cursor stops before it.
        var pending = Data()
        var consumed = cursor.offset
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let nl = pending[lineStart...].firstIndex(of: Self.newline) {
                let line = pending.subdata(in: lineStart..<nl)
                consumed += UInt64(line.count) + 1
                lineStart = nl + 1
                if line.range(of: Self.marker) != nil, let title = Self.decode(line) {
                    cursor.title = title
                }
            }
            pending = Data(pending[lineStart...])
        }
        cursor.offset = consumed
        cursors[transcriptPath] = cursor
        return cursor.title
    }

    private static func decode(_ line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let dict = object as? [String: Any],
              let title = dict["aiTitle"] as? String,
              !title.isEmpty
        else { return nil }
        return title
    }
}
