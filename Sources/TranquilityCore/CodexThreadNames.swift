import Foundation
import GRDB

/// What Codex calls a session, so a Codex row can wear a name.
///
/// Codex rows arrived on the grid nameless and fell back to their directory,
/// beside Claude Code rows carrying a real title (Robert, 30 Aug: "it has no
/// name in the row, so we should think about that fundamentally, if Codex
/// stores its name summary somewhere the way Claude does").
///
/// It does. `~/.codex/state_<n>.sqlite` has a `threads` table, and `name` is a
/// short model-written summary, the direct equivalent of Claude Code's title:
///
///     01a05338  Audit Kopi fixes in codebase
///     01a048ac  Investigate Tranquility Base crash
///
/// NOT `title`, which is the raw first user message and runs to hundreds of
/// words; not `first_user_message` or `preview`, which are the material that
/// summary was made from. `name` is the only one that reads like a title.
///
/// It is NOT in the rollout, which is the file this app already parses, so
/// there is no way to get it without reading their database. That is a
/// dependency on something undocumented and versioned, which the 28 Aug
/// research warned about at length for the rollout format. The difference
/// that makes it acceptable here is the blast radius: every failure mode ends
/// in a row keeping the name it has today. A missing title cannot corrupt
/// anything, cannot make a lamp lie, and cannot hide a session.
public enum CodexThreadNames {

    public static var defaultHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    /// The newest `state_<n>.sqlite`, by the number in its name.
    ///
    /// Codex versions this file and migrates forward: it is `state_5` today
    /// and will be `state_6`. Hardcoding the current one would read a stale
    /// database after their next migration and quietly serve names that stop
    /// updating, which is worse than no names at all because nothing would
    /// look wrong. Numeric, not lexical: `state_10` must beat `state_9`.
    ///
    /// Pure, so the ordering is tested without a Codex install.
    public static func newestState(among names: [String]) -> String? {
        names.compactMap { name -> (String, Int)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            let middle = name.dropFirst("state_".count).dropLast(".sqlite".count)
            guard let n = Int(middle) else { return nil }
            return (name, n)
        }
        .max { $0.1 < $1.1 }?.0
    }

    /// Every thread id that has a name, lowercased ids to match the rollout's.
    ///
    /// READ-ONLY, and every failure returns an empty map rather than throwing:
    /// this is a decoration on a row that already exists. Codex writing to the
    /// database while this reads is ordinary SQLite, and the worst outcome is
    /// a name a few seconds stale.
    public static func all(in home: URL = defaultHome) -> [String: String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: home.path),
              let newest = newestState(among: names) else { return [:] }
        let path = home.appendingPathComponent(newest).path

        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: path, configuration: configuration)
        else { return [:] }
        let rows = try? queue.read { db -> [(String, String)] in
            try Row.fetchAll(db, sql: """
                SELECT id, name FROM threads
                WHERE name IS NOT NULL AND name <> ''
                """)
                .compactMap { row in
                    guard let id: String = row["id"], let name: String = row["name"]
                    else { return nil }
                    return (id.lowercased(), name)
                }
        }
        return Dictionary(rows ?? [], uniquingKeysWith: { first, _ in first })
    }
}
