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

    /// What one attempt to read the database actually learned.
    ///
    /// The three answers used to be one. `read` returned `[:]` for "could not
    /// open the file", for "the query threw", and for "there are genuinely no
    /// named threads" alike, and both `try?` that produced it discarded the
    /// error. Downstream, an empty map does not leave a row alone — it
    /// RENAMES it, to its directory — so the whole grid read "Projects" and
    /// the only recoverable fact about why was that it had happened.
    ///
    /// It cost two days. The cause, once the error was finally allowed to
    /// exist (1 Sep), was one line of configuration: see `read`.
    public enum ReadOutcome: Sendable {
        /// The database answered. The map is the truth, empty or not.
        case names([String: String])
        /// It did not answer, and this is what it said instead.
        case unreadable(String)
    }

    /// The last map a read actually produced, and the clock that says when.
    ///
    /// A name is a decoration on a row that exists either way, so a failed
    /// read must cost nothing: the last good answer is kept. What changed on
    /// 1 Sep is that "failed" is now a fact the reader reports rather than a
    /// shape the caller infers from emptiness — so a database that genuinely
    /// holds no names is believed, and one that would not open is not.
    ///
    /// The map is also persisted (`diskPath`), because the in-memory cache is
    /// empty at launch and that is exactly when this failure is most visible:
    /// on 1 Sep the app restarted at 23:20:16 into a database it could not
    /// open, and every Codex row wore its directory name for 62 seconds with
    /// nothing to fall back on.
    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String: String] = [:]
        private var readAt = Date.distantPast
        private var loadedFromDisk = false

        func value(ttl: TimeInterval, read: () -> ReadOutcome) -> [String: String] {
            lock.lock(); defer { lock.unlock() }
            if !loadedFromDisk {
                loadedFromDisk = true
                names = CodexThreadNames.loadFromDisk()
                if !names.isEmpty {
                    trace?("codex names: opened with \(names.count) name(s) remembered "
                           + "from the last run")
                }
            }
            if Date().timeIntervalSince(readAt) < ttl, !names.isEmpty { return names }
            readAt = Date()
            switch read() {
            case .names(let fresh):
                if fresh.isEmpty, !names.isEmpty {
                    // Believed, not ignored: the database opened and said
                    // there are no names. Announced anyway, because it is
                    // still a surprising thing to hear from a machine that
                    // had some a moment ago.
                    trace?("codex names: the database opened and holds no names; "
                           + "dropping the \(names.count) we had")
                }
                names = fresh
                CodexThreadNames.saveToDisk(fresh)
                return fresh
            case .unreadable(let why):
                trace?("codex names: \(why) — keeping the \(names.count) name(s) already known")
                return names
            }
        }
    }

    private static let memory = Memory()

    /// Said out loud when a read fails, or when the answer changes shape.
    /// Silent by default; the app points it at its log.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// How long one read serves. The grid repaints several times a second and
    /// a name changes at conversational speed, so this is about not opening
    /// SQLite sixty times a minute, not about freshness.
    public static let ttl: TimeInterval = 2

    /// Every thread id that has a name — cached, and never blanked by a
    /// failed read. This is what every caller should use.
    public static func all() -> [String: String] {
        memory.value(ttl: ttl) { attemptRead(in: defaultHome) }
    }

    // MARK: - Remembering across launches

    /// Where the last good map is kept. Beside the app's own state, never in
    /// `~/.codex` — this app does not write into another tool's directory.
    static var diskPath: URL {
        QueueStore.supportDirectory.appendingPathComponent("codex-thread-names.json")
    }

    static func loadFromDisk() -> [String: String] {
        guard let data = try? Data(contentsOf: diskPath),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    static func saveToDisk(_ names: [String: String]) {
        guard !names.isEmpty, let data = try? JSONEncoder().encode(names) else { return }
        try? FileManager.default.createDirectory(
            at: QueueStore.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: diskPath, options: .atomic)
    }

    // MARK: - Reading

    /// Read the names, and say what happened if that did not work.
    ///
    /// **The bug this function exists in the shape it does because of.**
    /// `Configuration.readonly = true` is the obviously correct setting for
    /// reading another program's database, and against a WAL database it is
    /// a coin flip. SQLite in WAL mode needs the `-shm` shared-memory file,
    /// and a READ-ONLY connection cannot create one. While Codex has the
    /// database open the `-shm` exists and the read works; the moment the
    /// last Codex process exits, macOS deletes it and every subsequent
    /// read-only open fails:
    ///
    ///     $ sqlite3 'file:state_5.sqlite?mode=ro' 'select count(*) …'
    ///     Error: in prepare, unable to open database file (14)
    ///     $ sqlite3 'file:state_5.sqlite' 'PRAGMA query_only=ON; select …'
    ///     9
    ///
    /// Measured on this machine, 1 Sep 17:16, with the names sitting in the
    /// file the whole time. That is the entire "Projects" bug: the grid was
    /// reading Codex's database at exactly the moments Codex was not running,
    /// which is exactly when you go looking at a list of past agents.
    ///
    /// So: read-only first, because it is the right thing to ask for and it
    /// works whenever Codex is live. On failure, a read-WRITE handle with
    /// `PRAGMA query_only = ON` — which lets SQLite materialise the `-shm` it
    /// needs while the connection itself is forbidden from writing a byte.
    /// SQLite manages and removes those files itself; nothing of Codex's data
    /// is touched either way.
    public static func attemptRead(in home: URL = defaultHome) -> ReadOutcome {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: home.path) else {
            return .unreadable("\(home.path) could not be listed")
        }
        guard let newest = newestState(among: names) else {
            return .unreadable("no state_<n>.sqlite in \(home.path)")
        }
        let path = home.appendingPathComponent(newest).path

        switch query(path: path, readonly: true) {
        case .names(let map): return .names(map)
        case .unreadable(let readonlyWhy):
            switch query(path: path, readonly: false) {
            case .names(let map):
                trace?("codex names: read-only open failed (\(readonlyWhy)); "
                       + "read \(map.count) through a query-only handle instead")
                return .names(map)
            case .unreadable(let writableWhy):
                return .unreadable("\(newest) would not open — read-only: "
                                   + "\(readonlyWhy); query-only: \(writableWhy)")
            }
        }
    }

    /// One attempt against one handle. The errors are CAUGHT, not swallowed:
    /// every `try?` this function used to be is the reason the cause above
    /// took two days and a live reproduction to find.
    private static func query(path: String, readonly: Bool) -> ReadOutcome {
        var configuration = Configuration()
        configuration.readonly = readonly
        if !readonly {
            // Belt and braces: the handle is writable only so that SQLite may
            // create the WAL's `-shm`. Every statement it runs is refused
            // write access by SQLite itself.
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA query_only = ON")
            }
        }
        do {
            let queue = try DatabaseQueue(path: path, configuration: configuration)
            let rows = try queue.read { db -> [(String, String)] in
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
            return .names(Dictionary(rows, uniquingKeysWith: { first, _ in first }))
        } catch {
            return .unreadable("\(error)")
        }
    }

    /// The map alone, for callers that have nothing useful to do with a
    /// reason. Kept because `attemptRead` is the interesting one and this is
    /// how every existing caller and test already asks.
    public static func read(in home: URL = defaultHome) -> [String: String] {
        guard case .names(let map) = attemptRead(in: home) else { return [:] }
        return map
    }
}
