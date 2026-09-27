import Foundation
import GRDB

/// Everything the developer has said, as the manager reads it: every line of
/// the hands-free ledger they spoke and every dictation with words, the same
/// record the hub's Notes page shows (HubMirror.mirrorNotes). The manager's
/// `notes` tool answers "what did I say about pricing yesterday?" and picks
/// the range for "send what I said about the landing page to it" from here.
///
/// Read-only, and read where the record is: the ledger's files and the
/// panel's own database, opened read-only so the tool never holds a write
/// lock the panel wants.
public enum ManagerNotes {

    public struct Note: Equatable, Sendable {
        public let id: String          // ledger:<session>:<n> or dictation:<utterance id>
        public let at: Date
        public let source: String      // "handsfree" | "dictation"
        public let text: String
        public let agent: String?      // a dictation's target session

        public var json: [String: Any] {
            var o: [String: Any] = ["id": id, "at": ISO8601DateFormatter().string(from: at),
                                    "source": source, "text": text]
            if let agent { o["agent"] = agent }
            return o
        }
    }

    /// The notes in a window of time, oldest first; with `query`, only those
    /// sharing its words, the rarest words weighing most, the best `limit`
    /// of them kept and returned in the order said.
    public static func select(_ all: [Note], query: String?, since: Date?, until: Date?,
                              limit: Int) -> (notes: [Note], matched: Int) {
        var pool = all.filter { n in (since.map { n.at >= $0 } ?? true) && (until.map { n.at <= $0 } ?? true) }
        pool.sort { $0.at < $1.at }
        let words = Set((query ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count >= 3 })
        guard !words.isEmpty else { return (Array(pool.suffix(limit)), pool.count) }
        let lows = pool.map { $0.text.lowercased() }
        let n = Double(lows.count)
        var weight: [String: Double] = [:]
        for w in words { weight[w] = log((n + 1) / (1 + Double(lows.filter { $0.contains(w) }.count))) }
        let scored = lows.enumerated().compactMap { i, t -> (Int, Double)? in
            let s = words.filter { t.contains($0) }.reduce(0.0) { $0 + (weight[$1] ?? 0) }
            return s > 0 ? (i, s) : nil
        }
        let best = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 > $1.0 }.prefix(limit).map(\.0).sorted()
        return (best.map { pool[$0] }, scored.count)
    }

    /// A calendar day in `calendar`'s zone, start to the instant before the next.
    static func dayRange(_ day: String, calendar: Calendar) -> (start: Date, end: Date)? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, next.addingTimeInterval(-0.001))
    }

    /// The developer's own lines from the ledger's files (the current one and
    /// the one it last rotated out).
    static func ledgerNotes(directory: URL) -> [Note] {
        let read = HubMirror.readLedger(directory: directory, after: nil)
        return read.lines.compactMap { l in
            guard l.role == .user, !l.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Note(id: "ledger:\(l.session ?? "local"):\(l.n)", at: Date(timeIntervalSince1970: l.t),
                        source: "handsfree", text: l.text, agent: nil)
        }
    }

    /// Dictations with words, from the panel's database, opened read-only.
    static func dictationNotes(database: URL, since: Date?, until: Date?) -> [Note] {
        var config = Configuration()
        config.readonly = true
        guard FileManager.default.fileExists(atPath: database.path),
              let db = try? DatabaseQueue(path: database.path, configuration: config) else { return [] }
        let lo = since.map { Int64($0.timeIntervalSince1970 * 1000) } ?? Int64.min
        let hi = until.map { Int64($0.timeIntervalSince1970 * 1000) } ?? Int64.max
        let rows = (try? db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(HubMirror.dictationColumns) FROM utterances
                WHERE \(HubMirror.hasWords) AND createdAtMs >= ? AND createdAtMs <= ?
                ORDER BY createdAtMs, id
                """, arguments: [lo, hi])
        }) ?? []
        return rows.map { r in
            let ms: Int64 = r["createdAtMs"]
            let id: String = r["id"]
            let text: String = r["transcriptText"]
            let target: String? = r["targetSessionId"]
            return Note(id: "dictation:\(id)", at: Date(timeIntervalSince1970: Double(ms) / 1000),
                        source: "dictation", text: text, agent: target)
        }
    }

    /// The tool's answer for these arguments: `query` (words); `day`
    /// ("YYYY-MM-DD", this Mac's calendar day) or `since_minutes` and
    /// `until_minutes` (ago; until defaults to now); `limit` (at most 200).
    /// A day is a day: asked to turn "yesterday" into minutes, the model cut
    /// off a line said 25 hours ago (27 Sep, drills/range_eval.py).
    public static func answer(args: [String: Any], ledgerDirectory: URL, database: URL,
                              now: Date = Date(), calendar: Calendar = .current) -> [String: Any] {
        var since = (args["since_minutes"] as? Int).map { now.addingTimeInterval(-Double($0) * 60) }
        var until = (args["until_minutes"] as? Int).map { now.addingTimeInterval(-Double($0) * 60) }
        if let day = args["day"] as? String, let range = dayRange(day, calendar: calendar) {
            (since, until) = (range.start, range.end)
        }
        let limit = min(max((args["limit"] as? Int) ?? 80, 1), 200)
        let all = ledgerNotes(directory: ledgerDirectory) + dictationNotes(database: database, since: since, until: until)
        let (notes, matched) = select(all, query: args["query"] as? String, since: since, until: until, limit: limit)
        return ["notes": notes.map(\.json), "matched": matched]
    }
}
