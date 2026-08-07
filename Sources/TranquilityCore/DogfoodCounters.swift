import Foundation
import GRDB

// WS-E groundwork: the dogfood counters the spec wants "live from the first WS-A
// build" — attribution errors, terminal drop-backs, and the spoken-update
// actionability rate.
//
// Same shape as everything else in this store: an append-only log of facts, and
// counters computed by query, never stored. A stored counter can drift from the
// events it claims to count; a query cannot.

public enum DogfoodEventKind: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    /// An announcement was heard through to the end.
    case announcementSpoken = "announcement_spoken"
    /// The user replied or went to the session within a few minutes of hearing
    /// it. Derivable later from utterances + cursors; for now the app records it
    /// explicitly at the reply/goto action.
    case announcementActedOn = "announcement_acted_on"
    /// "Hear it again" was used — the first pass did not land.
    case replayRequested = "replay_requested"
    /// The ⌃⌃ depth-1 rationale pull.
    case depthOnePulled = "depth_one_pulled"
    /// "Go to session" was used: the spoken update was not enough and the user
    /// dropped back to the terminal. The app already has that action; recording
    /// it here is all Core needs to provide.
    case terminalDropBack = "terminal_drop_back"
    /// The wrong session was named or blamed. Manually or voice-reported later;
    /// the explicit record API is what WS-E needs now.
    case attributionError = "attribution_error"
}

public struct DogfoodSummary: Sendable {
    public let days: Int
    public let counts: [DogfoodEventKind: Int]

    /// Spoken-update actionability: acted-on over spoken. Nil when nothing was
    /// spoken in the window — 0/0 is "no data", not "0%".
    public var actionability: Double? {
        let spoken = counts[.announcementSpoken] ?? 0
        guard spoken > 0 else { return nil }
        return Double(counts[.announcementActedOn] ?? 0) / Double(spoken)
    }

    public init(days: Int, counts: [DogfoodEventKind: Int]) {
        self.days = days
        self.counts = counts
    }
}

extension QueueStore {
    /// Append one dogfood fact. `at` is injectable for tests; everything else
    /// stamps now.
    public func recordDogfood(
        _ kind: DogfoodEventKind, sessionId: String? = nil, note: String? = nil,
        at: Date = Date()
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO dogfood_event (atMs, kind, sessionId, note)
                VALUES (?, ?, ?, ?)
                """, arguments: [Int64(at.timeIntervalSince1970 * 1000),
                                  kind.rawValue, sessionId, note])
        }
    }

    /// Counts per kind since a cutoff. Computed, never cached.
    public func dogfoodCounts(since: Date) throws -> [DogfoodEventKind: Int] {
        let cutoffMs = Int64(since.timeIntervalSince1970 * 1000)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT kind, count(*) AS n FROM dogfood_event
                WHERE atMs >= ? GROUP BY kind
                """, arguments: [cutoffMs])
            var out: [DogfoodEventKind: Int] = [:]
            for row in rows {
                guard let kind = DogfoodEventKind(rawValue: row["kind"]) else { continue }
                out[kind] = row["n"]
            }
            return out
        }
    }

    /// The 7-day summary `tbase dogfood` prints.
    public func dogfoodSummary(days: Int = 7, now: Date = Date()) throws -> DogfoodSummary {
        DogfoodSummary(days: days, counts: try dogfoodCounts(
            since: now.addingTimeInterval(-Double(days) * 86_400)))
    }
}
