import Foundation

/// A session that continues another is the same conversation.
///
/// Pressing the left arrow on an empty prompt sends a Claude Code session to
/// the background. Claude Code does that by carrying the conversation on
/// under a NEW session id, and it writes one record at the end of the old
/// transcript to say so:
///
///     {"type":"continued-in","sessionId":"<old>","continuedInSessionId":"<new>"}
///
/// Nothing in the new transcript points back. So the only place the link
/// exists is the tail of the old file, and this is the one reader of it.
///
/// Ruled 10 Sep 2026, on "Hub design and organization": the app keyed hubs
/// by session id, Claude Code minted a new id for the continuation, and the
/// hub split in two: days of history under the old id, one turn under the
/// new one wearing the same name. Robert: "it's fucking lost its whole
/// history ... in what world should it lose its history?" It had not, but
/// two hubs for one conversation reads exactly like that. One conversation,
/// one hub: the origin's directory is the hub, the continuation's directory
/// is a link to it, and every member's turns and pages are listed together.
///
/// Pure over a map so it can be tested without a home directory; the map is
/// built from tail reads only, bounded to the last 2 KB of each transcript,
/// so scanning every project on the machine costs a few hundred small reads
/// and is cached for a few seconds.
public enum SessionLineage {

    /// continuation id (full) to the id it continued from (full).
    public typealias Map = [String: String]

    /// The record type Claude Code writes. Matched exactly.
    static let recordType = "continued-in"

    /// Read the link out of one transcript's tail, if it has one. The record
    /// is the last thing written to a session that moved on, so 2 KB is
    /// plenty; a file that ends some other way returns nil.
    public static func continuedIn(transcript: URL, tailBytes: Int = 2048) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"\(recordType)\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == recordType,
                  let next = obj["continuedInSessionId"] as? String, !next.isEmpty
            else { continue }
            return next
        }
        return nil
    }

    /// Every link on disk. Only Claude Code writes these, so only its
    /// project tree is walked.
    public static func scan(projects: URL = TranscriptArchive.projectsDirectory) -> Map {
        let fm = FileManager.default
        guard let projectNames = try? fm.contentsOfDirectory(atPath: projects.path) else { return [:] }
        var map: Map = [:]
        for project in projectNames {
            let dir = projects.appendingPathComponent(project, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let origin = String(name.dropLast(".jsonl".count))
                guard ArtifactStore.isPlausibleSession(origin),
                      let next = continuedIn(transcript: dir.appendingPathComponent(name))
                else { continue }
                map[next] = origin
            }
        }
        return map
    }

    /// The scan, cached. A hub write and a grid repaint both ask, and the
    /// answer changes once a day if that.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, map: Map)?
    public static func current(maxAge: TimeInterval = 15) -> Map {
        lock.lock(); defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < maxAge { return cached.map }
        let map = scan()
        cached = (Date(), map)
        return map
    }

    /// Where a conversation began. Follows the chain back; a loop, which the
    /// harness should never write, stops at the first repeat rather than
    /// spinning.
    public static func origin(of id: String, in map: Map) -> String {
        var here = id
        var seen: Set<String> = [id]
        while let earlier = map[here], seen.insert(earlier).inserted {
            here = earlier
        }
        return here
    }

    /// Every id in the conversation, origin first, in the order the
    /// conversation moved through them. A session nobody continued is a
    /// family of one.
    public static func family(of id: String, in map: Map) -> [String] {
        let root = origin(of: id, in: map)
        var chain = [root]
        var seen: Set<String> = [root]
        // Forward links, inverted from the map once: origin -> continuation.
        var forward: [String: String] = [:]
        for (next, earlier) in map { forward[earlier] = next }
        var here = root
        while let next = forward[here], seen.insert(next).inserted {
            chain.append(next)
            here = next
        }
        return chain
    }

    public static func origin(of id: String) -> String { origin(of: id, in: current()) }
    public static func family(of id: String) -> [String] { family(of: id, in: current()) }
}
