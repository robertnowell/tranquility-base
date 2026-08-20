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
/// **Bytes, not `String`, and the filter must not match on the main actor.**
/// Both halves of that were learned the hard way, 19 Aug, when this shipped as
/// a `String` haystack matched inline: Robert got a beach ball while typing.
/// Measured afterwards, which is the measurement that should have come first —
/// `String.contains` is Unicode-correct and therefore slow, and the cost lands
/// on every keystroke rather than once per opening:
///
///     String.contains, 60 haystacks of 2 MB   2963.6 ms      ← the beach ball
///     String.contains, 60 haystacks of 64 KB    92.9 ms
///     memmem,          60 haystacks of 2 MB     88.4 ms
///
/// So the text is kept as UTF-8 bytes and searched with `memmem`, which is 33×
/// faster at the same size — and even that runs off the main actor, because
/// 88 ms is still five dropped frames. The original error was optimising the
/// HARVEST, which happens once in the background and nobody can feel, while
/// leaving the MATCH on the main thread where every keystroke pays it.
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
    private var cache: [String: (size: UInt64, text: [UInt8])] = [:]

    /// Lowercased searchable UTF-8 for one transcript, empty if unreadable.
    /// Never call this on the main actor: it is bounded, not free.
    public func bytes(forTranscriptAt path: String) -> [UInt8] {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]
                    as? NSNumber)??.uint64Value ?? 0
        lock.lock()
        if let hit = cache[path], hit.size == size { lock.unlock(); return hit.text }
        lock.unlock()

        let text = Self.read(path: path, size: size)
        lock.lock(); cache[path] = (size, text); lock.unlock()
        return text
    }

    /// Byte-level substring, the operation the filter actually performs.
    /// `memmem` rather than any `String` API — see the type's note for the 33×.
    public static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        return hay.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in
                memmem(h.baseAddress!, h.count, n.baseAddress!, n.count) != nil
            }
        }
    }

    private static func read(path: String, size: UInt64) -> [UInt8] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
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
        // Lowercased ASCII-wise on the bytes: the needle is lowercased the same
        // way, so the two agree, and no `String` is ever built from megabytes.
        // A non-ASCII byte is left alone — it cannot be a case pair here, and
        // mangling it would only break a match that would otherwise work.
        var kept: [UInt8] = []
        kept.reserveCapacity(raw.count)
        let markers = injectedBytes
        for line in raw.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            let bytes = [UInt8](line)
            if markers.contains(where: { contains(bytes, $0) }) { continue }
            for b in bytes {
                kept.append(b >= 65 && b <= 90 ? b + 32 : b)
            }
            kept.append(UInt8(ascii: "\n"))
        }
        return kept
    }

    private static let injectedBytes: [[UInt8]] = injected.map { Array($0.utf8) }
}
