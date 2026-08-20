import Foundation

/// The words a session actually said, cut down to something a filter can hold.
///
/// Past Agents is a search surface, and its filter matched the name, the short
/// id and the project directory — everything ABOUT a session and nothing IN it.
/// Robert, 19 Aug: "if I search for microphone it'll find 'Microphone
/// initiation issue', but it might not find 'recording lost' or 'debug speaking
/// state issue' — the turns would have microphone in them."
///
/// Two things were measured before this was written, and both overturned the
/// obvious design.
///
/// **Bounding by turns is slower AND worse.** Distilling the last N turns needs
/// a JSON parse per line; a raw byte scan needs none. Over the 60 sessions the
/// list shows, on this machine: last-5-turns 0.07s and one hit for
/// "microphone"; last-60-turns 0.60s and four; a whole-file byte scan 0.28s and
/// eleven. The deepest bounded-by-turns variant cost twice the fastest
/// unbounded one and found a third as much. So the bound is on BYTES, which is
/// the dimension that actually controls the cost.
///
/// **Two megabytes is the whole benefit.** Capped at 2 MB (1 MB of head, 1 MB
/// of tail) the scan reads 105 MB instead of 366 MB and takes 0.10s instead of
/// 0.28s, for essentially the same recall — 11 hits against 11 for
/// "microphone", 16 against 20 for "spacing". A transcript's middle is where a
/// long session repeats itself; its head states the subject and its tail holds
/// what it was doing last, which is what a person searching remembers.
///
/// **Injected context had to go, or the filter matches everything.** Claude
/// Code writes the CLAUDE.md, the MCP server instructions and the skill listing
/// into every transcript as `attachment` records. Unfiltered, "klaviyo" matched
/// all 60 sessions on this machine — a filter that matches everything is worse
/// than no filter, because it looks like it worked. Dropping those records puts
/// it at 16 while leaving the real signal alone (microphone 11 → 10). It costs
/// a line split and no parse: 0.26s for all 60.
public final class TranscriptSearchText: @unchecked Sendable {

    public static let shared = TranscriptSearchText()

    /// 1 MB of head plus 1 MB of tail. See the type's note for the measurement.
    public static let byteCap = 2 << 20

    /// Records Claude Code injects rather than records the conversation wrote.
    /// Matched against the raw line, so no JSON is parsed on this path.
    private static let injected: [String] = [
        "\"type\":\"attachment\"", "\"type\":\"system\"", "\"isMeta\":true",
    ]

    private let lock = NSLock()
    /// Keyed by path, invalidated by size — an append-only file that has not
    /// grown cannot have changed, and reopening the list is the common case.
    private var cache: [String: (size: UInt64, text: String)] = [:]

    /// Lowercased searchable text for one transcript, or "" if unreadable.
    /// Never call this on the main actor: it is bounded, not free.
    public func text(forTranscriptAt path: String) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]
                    as? NSNumber)??.uint64Value ?? 0
        lock.lock()
        if let hit = cache[path], hit.size == size { lock.unlock(); return hit.text }
        lock.unlock()

        let text = Self.read(path: path, size: size)
        lock.lock(); cache[path] = (size, text); lock.unlock()
        return text
    }

    private static func read(path: String, size: UInt64) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        var raw = Data()
        if size <= UInt64(byteCap) {
            raw = (try? handle.readToEnd()) ?? Data()
        } else {
            let half = byteCap / 2
            raw = (try? handle.read(upToCount: half)) ?? Data()
            // The two halves are joined with a newline that may split a record
            // in the middle. That is deliberate and harmless: a torn line can
            // only ever LOSE a match at the seam, never invent one, and the
            // alternative is scanning the middle this cap exists to skip.
            try? handle.seek(toOffset: size - UInt64(half))
            raw.append(Data("\n".utf8))
            raw.append((try? handle.readToEnd()) ?? Data())
        }
        guard let whole = String(data: raw, encoding: .utf8)
                ?? String(decoding: raw, as: UTF8.self) as String? else { return "" }
        var kept = ""
        kept.reserveCapacity(whole.count / 2)
        for line in whole.split(separator: "\n", omittingEmptySubsequences: true) {
            if injected.contains(where: { line.contains($0) }) { continue }
            kept += line.lowercased()
            kept += "\n"
        }
        return kept
    }
}
