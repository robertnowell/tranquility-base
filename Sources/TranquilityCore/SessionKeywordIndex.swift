import Foundation
import GRDB

/// One local keyword index over what every agent said, kept on disk.
///
/// It holds one row for each MESSAGE, not one for each agent. That is what
/// lets a result say which sentence matched, who said it and when, and what
/// lets a session log be indexed by reading only the bytes it has grown by.
///
/// It replaced an index that held one row per agent and was deleted and
/// rebuilt on every opening of Past Agents. Measured on 15 Nov 2026: 38 of 38
/// openings rebuilt it (median 568 ms, worst 8 s), and the words "Preparing
/// search…" showed for that long each time. The excerpt it produced had no
/// speaker, no date and no highlight, and it could be a session id or a path.
///
/// Three rules follow from that record:
///
/// 1. **Nothing here is rebuilt.** `refresh` reads what changed and appends.
///    A log that has not grown costs one `stat`.
/// 2. **A search never waits for a refresh.** `search` is not isolated to the
///    actor; on disk it reads through a pool in WAL mode while a refresh
///    writes.
/// 3. **No model and no network.** This is keyword search (BM25).
public actor SessionKeywordIndex {

    /// Who said a thing, or what kind of text it is.
    public enum Role: String, Sendable, CaseIterable {
        case user, assistant, report, summary, title, metadata

        /// Text a person would recognise as a passage worth reading.
        public var isQuotable: Bool { self == .user || self == .assistant || self == .report || self == .summary }
        /// Said in the conversation itself. A result shows one of these when
        /// it has one, and is dated by it: a report page restates the
        /// conversation, its file clock moves whenever the page is stamped,
        /// and a hub page names agents it is not about.
        public var isSpoken: Bool { self == .user || self == .assistant }

        /// How much a match in this kind of text counts toward relevance. The
        /// same proportions the per-agent index gave its columns.
        var weight: Double {
            switch self {
            case .title: return 8
            case .user: return 5
            case .assistant: return 3
            case .report, .metadata: return 2
            case .summary: return 1
            }
        }
    }

    public enum Order: String, Sendable, CaseIterable { case recent, relevant }

    /// Everything the index should hold for one session.
    public struct Source: Sendable {
        public let id: String
        public let title: String
        /// Identity text: the id, the directory, the folder's name.
        public let metadata: String
        /// Stored briefs and summaries. Nil keeps what the index already has,
        /// so an unchanged session costs no store query.
        public let summary: String?
        public let activity: Date
        public let transcripts: [URL]
        public let reportDirectories: [URL]

        public init(id: String, title: String, metadata: String = "", summary: String? = "",
                    activity: Date, transcripts: [URL] = [], reportDirectories: [URL] = []) {
            self.id = id; self.title = title; self.metadata = metadata; self.summary = summary
            self.activity = activity; self.transcripts = transcripts
            self.reportDirectories = reportDirectories
        }
    }

    /// One agent's answer to a query: the passage to show, and how it ranks.
    public struct Match: Sendable, Equatable {
        /// The marks `excerpt` wraps around each matched word. Control
        /// characters, so no transcript text can be mistaken for them.
        public static let open: Character = "\u{2}"
        public static let close: Character = "\u{3}"

        public let id: String
        /// Where the shown passage came from. `.title` or `.metadata` means
        /// only the name or the identity matched, and `excerpt` is empty.
        public let role: Role
        public let at: Date
        public let excerpt: String
        /// How many quotable passages matched, the shown one included.
        public let count: Int
        public let tier: Int
        public let score: Double

        public init(id: String, role: Role = .title, at: Date = .distantPast, excerpt: String = "",
                    count: Int = 0, tier: Int = 4, score: Double = 0) {
            self.id = id; self.role = role; self.at = at; self.excerpt = excerpt
            self.count = count; self.tier = tier; self.score = score
        }

        /// The excerpt as plain words, without the marks.
        public var plainExcerpt: String {
            excerpt.filter { $0 != Match.open && $0 != Match.close }
        }
    }

    public struct Refresh: Sendable, Equatable {
        public var sources = 0
        public var filesRead = 0
        public var messagesAdded = 0
        public var unreadableSources = 0
        public var seconds: Double = 0
        /// Where a pass spent its time: reading logs, reading report pages,
        /// and writing rows. Logged, because the first build is the one cost
        /// a person can feel and its parts are not guessable.
        public var readSeconds: Double = 0
        public var reportSeconds: Double = 0
        public var writeSeconds: Double = 0
    }

    // MARK: - Storage

    /// The database, opened once and shared by the refresh and every search.
    private final class Store: @unchecked Sendable {
        private let url: URL?
        private let lock = NSLock()
        private var writer: (any DatabaseWriter)?
        init(url: URL?) { self.url = url }

        func database() throws -> any DatabaseWriter {
            lock.lock(); defer { lock.unlock() }
            if let writer { return writer }
            let opened: any DatabaseWriter
            do { opened = try open() } catch let error as DatabaseError where Self.damaged(error) {
                // The index is a copy of the logs. A damaged copy is deleted
                // and built again, never left to fail every pass for ever.
                try removeFiles()
                opened = try open()
            }
            writer = opened
            return opened
        }

        /// Forget a damaged index, so the next pass builds a new one.
        func discard(after error: Error) {
            guard let error = error as? DatabaseError, Self.damaged(error) else { return }
            lock.lock(); defer { lock.unlock() }
            writer = nil
            try? removeFiles()
        }

        private static func damaged(_ error: DatabaseError) -> Bool {
            error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
        }

        private func removeFiles() throws {
            guard let url else { return }
            for suffix in ["-wal", "-shm", ""] {
                let file = URL(fileURLWithPath: url.path + suffix)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                try FileManager.default.removeItem(at: file)
            }
        }

        private func open() throws -> any DatabaseWriter {
            let opened: any DatabaseWriter
            if let url {
                try PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
                // Two builds of the app can run at once and share this file.
                // The second writer waits for the first, it does not fail.
                var configuration = Configuration()
                configuration.busyMode = .timeout(10)
                opened = try DatabasePool(path: url.path, configuration: configuration)
                for suffix in ["", "-wal", "-shm"] {
                    PrivateStorage.protect(URL(fileURLWithPath: url.path + suffix))
                }
            } else { opened = try DatabaseQueue() }
            try opened.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS source(
                        path TEXT PRIMARY KEY, session TEXT NOT NULL, stamp TEXT NOT NULL,
                        offset INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE IF NOT EXISTS message(
                        id INTEGER PRIMARY KEY, path TEXT NOT NULL, session TEXT NOT NULL,
                        role TEXT NOT NULL, at REAL NOT NULL, text TEXT NOT NULL);
                    CREATE INDEX IF NOT EXISTS message_path ON message(path);
                    CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
                        text, content='message', content_rowid='id',
                        tokenize='porter unicode61 remove_diacritics 2');
                    CREATE TRIGGER IF NOT EXISTS message_ai AFTER INSERT ON message BEGIN
                        INSERT INTO message_fts(rowid, text) VALUES (new.id, new.text);
                    END;
                    CREATE TRIGGER IF NOT EXISTS message_ad AFTER DELETE ON message BEGIN
                        INSERT INTO message_fts(message_fts, rowid, text)
                        VALUES ('delete', old.id, old.text);
                    END;
                    """)
            }
            return opened
        }
    }

    private let store: Store
    public init(cacheURL: URL? = nil) { store = Store(url: cacheURL) }

    // MARK: - Refresh

    /// The most text one report page contributes, in characters.
    static let reportLimit = 200_000

    private struct FileStamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Double
        init(_ url: URL) throws {
            let a = try FileManager.default.attributesOfItem(atPath: url.path)
            inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            size = (a[.size] as? NSNumber)?.uint64Value ?? 0
            modified = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
        var text: String { "v2|\(inode)|\(size)|\(modified)" }
    }

    /// A hash that is the same in every process. `hashValue` is seeded per
    /// launch, so it cannot say whether stored text is still current.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    private static func insert(_ db: Database, path: String, session: String, role: Role,
                               at: Date, text: String) throws {
        try db.execute(sql: "INSERT INTO message(path,session,role,at,text) VALUES(?,?,?,?,?)",
                       arguments: [path, session, role.rawValue, at.timeIntervalSince1970, text])
    }

    private static func forget(_ db: Database, path: String) throws {
        try db.execute(sql: "DELETE FROM message WHERE path=?", arguments: [path])
        try db.execute(sql: "DELETE FROM source WHERE path=?", arguments: [path])
    }

    private static func remember(_ db: Database, path: String, session: String, stamp: String,
                                 offset: UInt64 = 0) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO source(path,session,stamp,offset) VALUES(?,?,?,?)
            """, arguments: [path, session, stamp, Int64(offset)])
    }

    /// Bring the index up to date with `sources`, reading only what changed.
    ///
    /// A log whose file is the same and has grown is read from the position
    /// the last read stopped at. A log that was replaced or cut short is read
    /// again from the start. Text for a session that is no longer in `sources`
    /// is removed, except when `sources` is empty: an empty list is a scan that
    /// failed, never an archive that emptied, and it must not erase the index.
    @discardableResult
    public func refresh(sources: [Source],
                        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) throws -> Refresh {
        do { return try pass(sources: sources, progress: progress) } catch {
            // Damage found part-way through a pass: this pass fails, and the
            // next one starts from an empty index.
            store.discard(after: error)
            throw error
        }
    }

    private func pass(sources: [Source],
                      progress: (@Sendable (_ done: Int, _ total: Int) -> Void)?) throws -> Refresh {
        let began = Date()
        let db = try store.database()
        var result = Refresh()
        result.sources = sources.count
        var known: [String: (stamp: String, offset: UInt64)] = [:]
        try db.read { connection in
            for row in try Row.fetchAll(connection, sql: "SELECT path,stamp,offset FROM source") {
                let offset: Int64 = row["offset"]
                known[row["path"]] = (row["stamp"], UInt64(max(0, offset)))
            }
        }
        var used: Set<String> = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            progress?(index, sources.count)
            var texts: [(Role, String?)] = [(.title, source.title), (.metadata, source.metadata),
                                            (.summary, source.summary)]
            texts = texts.map { ($0.0, $0.1?.trimmingCharacters(in: .whitespacesAndNewlines)) }
            for (role, text) in texts {
                let path = "meta:\(source.id):\(role.rawValue)"
                used.insert(path)
                guard let text else { continue }
                let stamp = Self.stableHash(text) + "|\(Int(source.activity.timeIntervalSince1970))"
                guard known[path]?.stamp != stamp else { continue }
                try db.write { connection in
                    try Self.forget(connection, path: path)
                    if !text.isEmpty {
                        try Self.insert(connection, path: path, session: source.id, role: role,
                                        at: source.activity, text: text)
                    }
                    try Self.remember(connection, path: path, session: source.id, stamp: stamp)
                }
            }
            for url in source.transcripts {
                let path = url.path
                used.insert(path)
                do {
                    let stamp = try FileStamp(url)
                    let held = known[path]
                    if held?.stamp == stamp.text { continue }
                    // The same file, longer than before: read the new bytes.
                    var from: UInt64 = 0
                    if let held, held.offset <= stamp.size,
                       held.stamp.hasPrefix("v2|\(stamp.inode)|") { from = held.offset }
                    let readBegan = Date()
                    let read = try autoreleasepool { try SessionSearchText.read(url, from: from) }
                    result.readSeconds += Date().timeIntervalSince(readBegan)
                    let writeBegan = Date()
                    defer { result.writeSeconds += Date().timeIntervalSince(writeBegan) }
                    try db.write { connection in
                        if from == 0 { try Self.forget(connection, path: path) }
                        for message in read.messages {
                            let role: Role = message.role == "user" ? .user : .assistant
                            try Self.insert(connection, path: path, session: source.id, role: role,
                                            at: message.at, text: message.text)
                        }
                        try Self.remember(connection, path: path, session: source.id,
                                          stamp: stamp.text, offset: read.offset)
                    }
                    result.filesRead += 1
                    result.messagesAdded += read.messages.count
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // An unreadable log keeps none of its old text: a result
                    // that quotes a file nobody can open is worse than none.
                    result.unreadableSources += 1
                    try db.write { try Self.forget($0, path: path) }
                }
            }
            for directory in source.reportDirectories {
                let hub = directory.resolvingSymlinksInPath().path
                guard let walker = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in walker where url.pathExtension.lowercased() == "html" {
                    try Task.checkCancellation()
                    // The generated hub repeats the same turns and links to other
                    // agents. Index the actual reports rather than that navigation.
                    // A report in a folder of its own is `index.html` too, and
                    // that one is a report.
                    guard url.lastPathComponent != "index.html"
                            || url.deletingLastPathComponent().resolvingSymlinksInPath().path != hub
                    else { continue }
                    let path = url.path
                    used.insert(path)
                    do {
                        let stamp = try FileStamp(url)
                        guard known[path]?.stamp != stamp.text else { continue }
                        let reportBegan = Date()
                        defer { result.reportSeconds += Date().timeIntervalSince(reportBegan) }
                        // Bounded: one page here was 1.7 MB of pasted log, and
                        // an excerpt is cut from the stored text on every search.
                        let text = String(HubRead.text(try String(contentsOf: url, encoding: .utf8))
                            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.reportLimit))
                        try db.write { connection in
                            try Self.forget(connection, path: path)
                            if !text.isEmpty {
                                try Self.insert(connection, path: path, session: source.id, role: .report,
                                                at: Date(timeIntervalSince1970: stamp.modified), text: text)
                            }
                            try Self.remember(connection, path: path, session: source.id, stamp: stamp.text)
                        }
                        result.filesRead += 1
                        result.messagesAdded += text.isEmpty ? 0 : 1
                    } catch {
                        result.unreadableSources += 1
                        try db.write { try Self.forget($0, path: path) }
                    }
                }
            }
        }
        progress?(sources.count, sources.count)
        if !sources.isEmpty {
            let gone = known.keys.filter { !used.contains($0) }
            if !gone.isEmpty {
                try db.write { connection in
                    for path in gone {
                        try Task.checkCancellation()
                        try Self.forget(connection, path: path)
                    }
                }
            }
        }
        result.seconds = Date().timeIntervalSince(began)
        return result
    }

    /// How much the index holds. For the summary line and the log.
    public nonisolated func counts() throws -> (sessions: Int, messages: Int) {
        try store.database().read { db in
            (try Int.fetchOne(db, sql: "SELECT count(DISTINCT session) FROM message") ?? 0,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM message") ?? 0)
        }
    }

    // MARK: - Search

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private struct Hit {
        let rowid: Int64
        let session: String
        let role: Role
        let at: Double
        let score: Double
        var phrase = false
    }

    /// One match per session, ordered.
    ///
    /// Every word is required, and the last one may be a prefix, so results
    /// narrow as you type. `recent` orders by the newest passage that matched
    /// and shows that passage. `relevant` orders by where the words matched
    /// (the name, then your words, then the agent's) and shows the best one.
    ///
    /// Only the first `excerpts` results carry their passage. Cutting an
    /// excerpt reads the stored text, and measured on a real archive it was
    /// 126 ms of a 142 ms answer for 300 results; a list draws fifty.
    public nonisolated func search(_ query: String, order: Order = .relevant,
                                   limit: Int = 300, excerpts: Int = .max) throws -> [Match] {
        try Task.checkCancellation()
        let tokens = Self.words(query)
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.enumerated().map { i, word in
            "\"\(word)\"" + (i == tokens.count - 1 ? "*" : "")
        }.joined(separator: " AND ")
        let phrase = tokens.joined(separator: " ")
        return try store.database().read { db in
            var hits: [Hit] = try Row.fetchAll(db, sql: """
                SELECT m.id AS id, m.session AS session, m.role AS role, m.at AS at,
                       bm25(message_fts) AS score
                FROM message_fts JOIN message m ON m.id = message_fts.rowid
                WHERE message_fts MATCH ?
                """, arguments: [expression]).compactMap { row in
                    guard let role = Role(rawValue: row["role"]) else { return nil }
                    return Hit(rowid: row["id"], session: row["session"], role: role,
                               at: row["at"], score: row["score"])
                }
            guard !hits.isEmpty else { return [] }
            // The phrase tier asks the same inverted index, never a second
            // scan through every matching conversation on a keystroke.
            if tokens.count > 1 {
                let together = Set(try Int64.fetchAll(db,
                    sql: "SELECT rowid FROM message_fts WHERE message_fts MATCH ?",
                    arguments: ["\"\(phrase)\"*"]))
                for i in hits.indices { hits[i].phrase = together.contains(hits[i].rowid) }
            } else {
                for i in hits.indices { hits[i].phrase = true }
            }
            try Task.checkCancellation()

            let titleHits = hits.filter { $0.role == .title && $0.phrase }.map(\.rowid)
            var exactTitles: Set<Int64> = []
            if !titleHits.isEmpty {
                let marks = titleHits.map { _ in "?" }.joined(separator: ",")
                for row in try Row.fetchAll(db, sql: "SELECT id,text FROM message WHERE id IN (\(marks))",
                                            arguments: StatementArguments(titleHits)) {
                    let text: String = row["text"]
                    if Self.words(text).joined(separator: " ") == phrase { exactTitles.insert(row["id"]) }
                }
            }

            struct Group {
                var count = 0
                var tier = 4
                var score = Double.greatestFiniteMagnitude
                var newest = -Double.greatestFiniteMagnitude
                var shown: Hit?
                var shownRank = Double.greatestFiniteMagnitude
                var datedBy = 3
            }
            var groups: [String: Group] = [:]
            for hit in hits {
                var group = groups[hit.session] ?? Group()
                let weighted = hit.score * hit.role.weight
                group.score = min(group.score, weighted)
                var tier = 4
                if hit.phrase {
                    switch hit.role {
                    case .title: tier = exactTitles.contains(hit.rowid) ? 0 : 1
                    case .user: tier = 2
                    case .assistant, .report: tier = 3
                    case .summary, .metadata: tier = 4
                    }
                }
                group.tier = min(group.tier, tier)
                if hit.role.isQuotable {
                    group.count += 1
                    // Which passage stands for this agent: something said in
                    // the conversation before anything written about it, then
                    // the newest one, or the one the words fit best. A phrase
                    // beats scattered words.
                    let written: Double = hit.role.isSpoken ? 0 : 1e15
                    let rank = written + (order == .recent ? -hit.at
                        : (hit.phrase ? 0 : 1_000_000) + weighted)
                    if rank < group.shownRank { group.shown = hit; group.shownRank = rank }
                }
                groups[hit.session] = group
            }
            // An agent is dated by the newest thing SAID that matched; failing
            // that by a page that matched; failing that, for a name-only
            // match, by when the agent last moved.
            for kind in 0..<3 {
                for hit in hits {
                    let fits = kind == 0 ? hit.role.isSpoken
                        : kind == 1 ? hit.role.isQuotable : true
                    guard fits, var group = groups[hit.session], group.datedBy >= kind else { continue }
                    group.newest = group.datedBy == kind ? max(group.newest, hit.at) : hit.at
                    group.datedBy = kind
                    groups[hit.session] = group
                }
            }
            var ordered = groups.map { (id: $0.key, group: $0.value) }
            ordered.sort { a, b in
                if order == .relevant {
                    if a.group.tier != b.group.tier { return a.group.tier < b.group.tier }
                    if a.group.score != b.group.score { return a.group.score < b.group.score }
                }
                if a.group.newest != b.group.newest { return a.group.newest > b.group.newest }
                return a.id < b.id
            }
            if ordered.count > limit { ordered.removeLast(ordered.count - limit) }

            let shown = ordered.prefix(excerpts).compactMap { $0.group.shown?.rowid }
            var excerpts: [Int64: String] = [:]
            // SQLite allows 999 bound values by default; stay well inside it.
            for start in stride(from: 0, to: shown.count, by: 400) {
                try Task.checkCancellation()
                let slice = Array(shown[start..<min(start + 400, shown.count)])
                let marks = slice.map { _ in "?" }.joined(separator: ",")
                let arguments: [DatabaseValueConvertible] = [expression] + slice
                for row in try Row.fetchAll(db, sql: """
                    SELECT rowid, snippet(message_fts, 0, char(2), char(3), '…', 24) AS excerpt
                    FROM message_fts WHERE message_fts MATCH ? AND rowid IN (\(marks))
                    """, arguments: StatementArguments(arguments)) {
                    let text: String = row["excerpt"]
                    excerpts[row["rowid"]] = text.split(whereSeparator: \.isWhitespace)
                        .joined(separator: " ")
                }
            }
            return ordered.map { entry in
                let group = entry.group
                return Match(id: entry.id, role: group.shown?.role ?? .title,
                             at: Date(timeIntervalSince1970: group.newest),
                             excerpt: group.shown.flatMap { excerpts[$0.rowid] } ?? "",
                             count: group.count, tier: group.tier, score: group.score)
            }
        }
    }

    /// Fold matches that belong to one row into one match, and order again.
    ///
    /// The index knows sessions. The list knows agents, and one agent can be
    /// several sessions: a conversation that was continued under a new id is
    /// one row. `owner` names the row a session belongs to, or nil for a
    /// session that has no row, which is dropped.
    public static func merge(_ matches: [Match], order: Order,
                             owner: (String) -> String?) -> [Match] {
        var merged: [String: Match] = [:]
        var sequence: [String] = []
        for match in matches {
            guard let id = owner(match.id) else { continue }
            guard let held = merged[id] else {
                sequence.append(id)
                merged[id] = Match(id: id, role: match.role, at: match.at, excerpt: match.excerpt,
                                   count: match.count, tier: match.tier, score: match.score)
                continue
            }
            // `matches` arrive in order, so the first of a family already
            // carries the passage to show unless it had none.
            let lead = held.excerpt.isEmpty && !match.excerpt.isEmpty ? match : held
            merged[id] = Match(id: id, role: lead.role, at: max(held.at, match.at),
                               excerpt: lead.excerpt, count: held.count + match.count,
                               tier: min(held.tier, match.tier), score: min(held.score, match.score))
        }
        return sequence.compactMap { merged[$0] }.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if order == .relevant {
                if x.tier != y.tier { return x.tier < y.tier }
                if x.score != y.score { return x.score < y.score }
            }
            if x.at != y.at { return x.at > y.at }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - Sources

    /// What the index should hold for every session whose log is on disk.
    ///
    /// `unchangedSince` is when the last refresh began. A session that has not
    /// moved since then keeps its stored summary, which saves one store query
    /// for each of several hundred sessions on every pass.
    public static func sources(discovered: [SessionDiscovery.Session], store: QueueStore?,
                               reportsRoot: URL, unchangedSince: Date? = nil,
                               folder: (String) -> String? = { _ in nil }) throws -> [Source] {
        let known = try store?.allKnownSessions(limit: Int.max) ?? []
        let events = Dictionary(known.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        return try discovered.map { session in
            try Task.checkCancellation()
            let id = session.sessionId
            let event = events[id]
            let title = GridAssembler.tabDisplayName(discovered: session.title, sessionId: id,
                                                     callsign: event?.callsign, cwd: session.cwd)
            let metadata = [id, session.cwd ?? "", folder(id) ?? ""].joined(separator: " ")
            var summary: String?
            if unchangedSince.map({ session.lastActivityAt >= $0 }) ?? true {
                var parts: [String] = []
                for brief in try store?.briefs(for: id, limit: Int.max) ?? [] {
                    let fields: [String?] = [brief.topic, brief.goal, brief.happened,
                        brief.headline, brief.deck, brief.findings, brief.solution,
                        brief.rationale, brief.recap, brief.proposal, brief.question]
                    parts.append(fields.compactMap { $0 }.joined(separator: "\n"))
                }
                if let event { parts.append(event.summaryText ?? "") }
                summary = parts.joined(separator: "\n")
            }
            return Source(id: id, title: title, metadata: metadata, summary: summary,
                          activity: session.lastActivityAt,
                          transcripts: [URL(fileURLWithPath: session.transcriptPath).resolvingSymlinksInPath()],
                          reportDirectories: [reportsRoot.appendingPathComponent(id).resolvingSymlinksInPath()])
        }
    }
}
