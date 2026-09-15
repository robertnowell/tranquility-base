import Foundation
import GRDB

/// One local keyword index. Preparation and queries are serialized off the UI
/// actor, and replacing its documents is atomic. No model or network is involved.
public actor SessionKeywordIndex {
    public struct Document: Sendable {
        public let id: String
        public let title: String
        public var metadata: String
        public let activity: Date
        public var userText: String
        public var assistantText: String
        public var reports: String
        public var summary: String

        public init(id: String, title: String, metadata: String = "", activity: Date,
                    userText: String = "", assistantText: String = "",
                    reports: String = "", summary: String = "") {
            self.id = id; self.title = title; self.metadata = metadata; self.activity = activity
            self.userText = userText; self.assistantText = assistantText
            self.reports = reports; self.summary = summary
        }
    }

    public struct Source: Sendable {
        public var document: Document
        public let transcripts: [URL]
        public let reportDirectories: [URL]
        public init(document: Document, transcripts: [URL] = [], reportDirectories: [URL] = []) {
            self.document = document; self.transcripts = transcripts
            self.reportDirectories = reportDirectories
        }
    }

    public struct Match: Sendable, Equatable {
        public let id: String
        public let excerpt: String
        public init(id: String, excerpt: String) { self.id = id; self.excerpt = excerpt }
    }

    public struct Preparation: Sendable {
        public let documents: Int
        public let unreadableSources: Int
    }

    private let cacheURL: URL?
    private var queue: DatabaseQueue?
    public init(cacheURL: URL? = nil) { self.cacheURL = cacheURL }

    private func database() throws -> DatabaseQueue {
        if let queue { return queue }
        let opened: DatabaseQueue
        if let cacheURL {
            try PrivateStorage.createDirectory(at: cacheURL.deletingLastPathComponent())
            opened = try DatabaseQueue(path: cacheURL.path)
            PrivateStorage.protect(cacheURL)
        } else { opened = try DatabaseQueue() }
        try opened.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS search_source (
                    path TEXT PRIMARY KEY, stamp TEXT NOT NULL,
                    since REAL NOT NULL, payload BLOB NOT NULL);
                CREATE VIRTUAL TABLE IF NOT EXISTS session_keyword_v1 USING fts5(
                    id UNINDEXED, activity UNINDEXED, title, metadata,
                    userText, assistantText, reports, summary,
                    tokenize='porter unicode61 remove_diacritics 2');
                """)
        }
        queue = opened
        return opened
    }

    public func replace(documents: [Document]) throws {
        let db = try database()
        try db.write { connection in
            try connection.execute(sql: "DELETE FROM session_keyword_v1")
            for document in documents {
                try Task.checkCancellation()
                try connection.execute(sql: """
                    INSERT INTO session_keyword_v1
                    (id,activity,title,metadata,userText,assistantText,reports,summary)
                    VALUES (?,?,?,?,?,?,?,?)
                    """, arguments: [document.id, document.activity.timeIntervalSince1970,
                                       document.title, document.metadata, document.userText,
                                       document.assistantText, document.reports, document.summary])
            }
        }
    }

    /// The file clock only invalidates cached text; it never ranks an agent.
    private func stamp(_ url: URL) throws -> String {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return "v1|\(a[.size] ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(a[.systemFileNumber] ?? 0)"
    }

    private func cached<T: Codable>(_ url: URL, since: Date,
                                    read: () throws -> T) throws -> T {
        try autoreleasepool {
            let db = try database()
            let before = try stamp(url)
            if let row = try db.read({ try Row.fetchOne($0,
                sql: "SELECT stamp,since,payload FROM search_source WHERE path=?",
                arguments: [url.path]) }),
               (row["stamp"] as String) == before,
               (row["since"] as Double) <= since.timeIntervalSince1970,
               let value = try? JSONDecoder().decode(T.self, from: row["payload"] as Data) {
                return value
            }
            let value = try read()
            // An append during the read is usable now but must be read again next time.
            if try stamp(url) == before {
                let data = try JSONEncoder().encode(value)
                try db.write { try $0.execute(sql: """
                    INSERT OR REPLACE INTO search_source(path,stamp,since,payload) VALUES(?,?,?,?)
                    """, arguments: [url.path, before, since.timeIntervalSince1970, data]) }
            }
            return value
        }
    }

    /// Resolve each visible conversation's continuations once, on a worker.
    /// Stored briefs also cover sessions whose transcript is on another machine.
    public static func sources(documents: [Document], discovered: [SessionDiscovery.Session],
                               store: QueueStore?, since: Date, reportsRoot: URL) throws -> [Source] {
        let archive = Dictionary(discovered.map { ($0.sessionId, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let known = try store?.allKnownSessions(limit: Int.max) ?? []
        let events = Dictionary(known.map { ($0.sessionId, $0) },
                                uniquingKeysWith: { first, _ in first })
        let lineage = SessionLineage.current()
        return try documents.map { original in
            try Task.checkCancellation()
            var document = original
            var transcripts: Set<URL> = []
            var reports: Set<URL> = []
            let family = Set(SessionLineage.family(of: original.id, in: lineage) + [original.id])
            for id in family.sorted() {
                if let path = archive[id]?.transcriptPath ?? events[id]?.transcriptPath {
                    transcripts.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath())
                }
                document.metadata += "\n" + id + " " + (archive[id]?.title ?? "")
                reports.insert(reportsRoot.appendingPathComponent(id).resolvingSymlinksInPath())
                let briefs = try store?.briefs(for: id, limit: Int.max) ?? []
                for brief in briefs
                    where Double(brief.atMs) / 1000 >= since.timeIntervalSince1970 {
                    let fields: [String?] = [brief.topic, brief.goal, brief.happened,
                        brief.headline, brief.deck, brief.findings, brief.solution,
                        brief.rationale, brief.recap, brief.proposal, brief.question]
                    document.summary += "\n" + fields.compactMap { $0 }.joined(separator: "\n")
                }
                if let event = events[id], Double(event.createdAtMs) / 1000 >= since.timeIntervalSince1970 {
                    document.assistantText += "\n" + (event.lastAssistantMessage ?? "")
                    document.summary += "\n" + (event.summaryText ?? "")
                }
            }
            return Source(document: document, transcripts: transcripts.sorted { $0.path < $1.path },
                          reportDirectories: reports.sorted { $0.path < $1.path })
        }
    }

    public func prepare(sources: [Source], since: Date) throws -> Preparation {
        var documents: [Document] = []
        var failures = 0
        var used: Set<String> = []
        for source in sources {
            try Task.checkCancellation()
            var document = source.document
            for path in source.transcripts {
                used.insert(path.path)
                do {
                    let messages: [SessionSearchText.Message] = try cached(path, since: since) {
                        try SessionSearchText.read(path, since: since)
                    }
                    for m in messages where m.at >= since {
                        if m.role == "user" { document.userText += "\n" + m.text }
                        else { document.assistantText += "\n" + m.text }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failures += 1 }
            }
            for directory in source.reportDirectories {
                guard let walker = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for case let path as URL in walker where path.pathExtension.lowercased() == "html" {
                    try Task.checkCancellation()
                    // The generated hub repeats the same turns and links to other
                    // agents. Index the actual reports rather than that navigation.
                    guard path.lastPathComponent != "index.html" else { continue }
                    used.insert(path.path)
                    do {
                        let text: String = try cached(path, since: since) {
                            HubRead.text(try String(contentsOf: path, encoding: .utf8))
                        }
                        document.reports += "\n" + text
                    } catch { failures += 1 }
                }
            }
            documents.append(document)
        }
        try replace(documents: documents)
        let db = try database()
        try db.write { connection in
            for path in try String.fetchAll(connection, sql: "SELECT path FROM search_source")
                where !used.contains(path) {
                try connection.execute(sql: "DELETE FROM search_source WHERE path=?", arguments: [path])
            }
        }
        return Preparation(documents: documents.count, unreadableSources: failures)
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    public func search(_ query: String) throws -> [Match] {
        try Task.checkCancellation()
        let tokens = Self.words(query)
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.enumerated().map { i, word in
            "\"\(word)\"" + (i == tokens.count - 1 ? "*" : "")
        }.joined(separator: " AND ")
        let phrase = tokens.joined(separator: " ")
        let db = try database()
        return try db.read { connection in
            let rows = try Row.fetchAll(connection, sql: """
                SELECT id,title,
                       snippet(session_keyword_v1,-1,'','','…',28) AS excerpt,
                       bm25(session_keyword_v1,0,0,8,2,5,3,2,1) AS score
                FROM session_keyword_v1 WHERE session_keyword_v1 MATCH ?
                ORDER BY score,CAST(activity AS REAL) DESC,id
                """, arguments: [expression])
            // Phrase tiers use the same inverted index, never a second scan
            // through every matching session's conversation on a keystroke.
            func phraseIDs(_ columns: String) throws -> Set<String> {
                let match = "\(columns) : \"\(phrase)\"*"
                return Set(try String.fetchAll(connection,
                    sql: "SELECT id FROM session_keyword_v1 WHERE session_keyword_v1 MATCH ?",
                    arguments: [match]))
            }
            let titlePhrase = try phraseIDs("title")
            let userPhrase = try phraseIDs("userText")
            let otherPhrase = try phraseIDs("{assistantText reports}")
            func tier(_ row: Row) -> Int {
                let id: String = row["id"]
                let title: String = row["title"]
                if Self.words(title).joined(separator: " ") == phrase { return 0 }
                if titlePhrase.contains(id) { return 1 }
                if userPhrase.contains(id) { return 2 }
                if otherPhrase.contains(id) { return 3 }
                return 4
            }
            // Explicit original offsets preserve BM25/recency/ID order within a tier.
            let ranked: [(offset: Int, row: Row, tier: Int)] = rows.enumerated().map {
                (offset: $0.offset, row: $0.element, tier: tier($0.element))
            }
            let ordered = ranked.sorted { a, b in
                a.tier == b.tier ? a.offset < b.offset : a.tier < b.tier
            }
            return ordered.map { Match(id: $0.row["id"], excerpt: $0.row["excerpt"]) }
        }
    }
}
