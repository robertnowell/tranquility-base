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

        // A COLD read of a large transcript used to scan the whole file, which
        // is fine for the one session being announced and ruinous for a list:
        // discovering a week of sessions meant 317MB across 41 files and 5.2s
        // before the panel could paint. A first paint that stalls five seconds
        // is the same complaint as an empty panel, one layer down.
        //
        // Measured before changing it, across every transcript over 200KB on
        // this machine: the LAST ai-title sits within 30KB of the end in 40 of
        // 40 files, because Claude Code re-mints the title as the conversation
        // moves. The first sits within the first 1MB. So two windows answer the
        // question exactly, and the middle of a large file cannot contain the
        // answer unless titling stopped partway — in which case the row falls
        // back to its callsign, which is a missing title rather than a wrong
        // one. Small files take the original full scan, so nothing about the
        // incremental append behaviour changes.
        if cursor.offset == 0, size > UInt64(Self.headWindow + Self.tailWindow) {
            if let seeded = Self.seed(handle: handle, size: size) {
                cursors[transcriptPath] = seeded
                return seeded.title
            }
        }
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

    /// Wide enough for the LAST title, which is the one the tab shows: measured
    /// within 30KB of the end on all 40 transcripts over 200KB here. 256KB is
    /// eight times the worst case observed.
    static let tailWindow = 1 << 18
    /// Only read when the tail has no title at all — a session titled once,
    /// early, and never again. Measured: the first title is within the first
    /// 1MB on every such file, one of them at 0.91MB.
    static let headWindow = 1 << 20

    /// Tail first, head only if the tail came up empty. That ordering is the
    /// whole cost: the tail alone answers for every file measured, so the head
    /// read almost never happens, and a week of sessions costs ~10MB of reads
    /// rather than the 317MB a full scan of each file cost.
    private static func seed(handle: FileHandle, size: UInt64) -> Cursor? {
        let tailStart = size - UInt64(tailWindow)
        try? handle.seek(toOffset: tailStart)
        guard let tail = try? handle.readToEnd() else { return nil }
        var title = lastTitle(in: tail, dropFirstPartial: true)

        if title == nil {
            try? handle.seek(toOffset: 0)
            if let head = try? handle.read(upToCount: headWindow) {
                title = lastTitle(in: head, dropFirstPartial: false)
            }
        }

        // Park at the end of the last COMPLETE line, exactly as the incremental
        // path does, so a half-flushed record is re-read rather than split.
        guard let lastNewline = tail.lastIndex(of: newline) else { return nil }
        let consumed = tailStart + UInt64(tail.distance(from: tail.startIndex, to: lastNewline)) + 1
        return Cursor(offset: consumed, title: title)
    }

    /// The last `aiTitle` among whole lines of a window. The first line is
    /// dropped when the window began at a byte offset, because seeking lands
    /// mid-record and half a JSON object is not a record.
    private static func lastTitle(in window: Data, dropFirstPartial: Bool) -> String? {
        var found: String?
        var start = window.startIndex
        if dropFirstPartial, let first = window.firstIndex(of: newline) {
            start = window.index(after: first)
        }
        var cursor = start
        while let nl = window[cursor...].firstIndex(of: newline) {
            let line = window.subdata(in: cursor..<nl)
            if line.range(of: marker) != nil, let title = decode(line) { found = title }
            cursor = window.index(after: nl)
        }
        return found
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
