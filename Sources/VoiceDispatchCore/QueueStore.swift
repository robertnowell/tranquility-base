import Foundation
import GRDB

/// Durable queue backing the whole loop.
///
/// Two writers touch this file: the shell hook (via the `sqlite3` CLI, on every
/// turn end across every session) and the app. WAL mode plus a busy timeout is what
/// makes that safe — the hook must never block or fail a real Claude Code turn.
public final class QueueStore: Sendable {
    public let dbQueue: DatabaseQueue

    // MARK: - Locations

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VoiceDispatch", isDirectory: true)
    }

    public static var databaseURL: URL {
        supportDirectory.appendingPathComponent("queue.sqlite")
    }

    public static var audioDirectory: URL {
        supportDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    // MARK: - Open

    public init(url: URL? = nil) throws {
        let dbURL = url ?? Self.databaseURL
        try? PrivateStorage.createDirectory(at: dbURL.deletingLastPathComponent())
        try? PrivateStorage.createDirectory(at: Self.audioDirectory)
        defer {
            // GRDB creates the database 0644, and the -wal and -shm siblings too.
            // The directory being 0700 already denies access, but the file modes
            // should not depend on that alone.
            PrivateStorage.protect(dbURL)
            PrivateStorage.protect(URL(fileURLWithPath: dbURL.path + "-wal"))
            PrivateStorage.protect(URL(fileURLWithPath: dbURL.path + "-shm"))
        }

        var config = Configuration()
        // The hook may be writing from another process at any moment. Wait rather
        // than fail; 2s is far longer than any insert should ever need.
        config.busyMode = .timeout(2.0)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_events_and_utterances") { db in
            try db.create(table: "events") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAtMs", .integer).notNull()
                t.column("hookEvent", .text).notNull()
                t.column("sessionId", .text).notNull()
                t.column("promptId", .text)
                t.column("cwd", .text)
                t.column("transcriptPath", .text)
                t.column("lastAssistantMessage", .text)
                t.column("notificationMatcher", .text)
                t.column("status", .text).notNull().defaults(to: EventStatus.new.rawValue)
                t.column("summaryText", .text)
                t.column("summaryError", .text)
                t.column("announcedAtMs", .integer)
            }
            try db.create(index: "idx_events_status", on: "events", columns: ["status"])
            try db.create(index: "idx_events_created", on: "events", columns: ["createdAtMs"])

            // Dedupe guard. A turn that fans out to subagents shares one promptId;
            // the hook only writes Stop, but a double-fire would otherwise duplicate.
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_events_dedupe
                ON events(sessionId, promptId)
                WHERE promptId IS NOT NULL AND hookEvent = 'Stop'
                """)

            try db.create(table: "utterances") { t in
                t.column("id", .text).primaryKey()
                t.column("eventId", .text).references("events", onDelete: .setNull)
                t.column("createdAtMs", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("audioPath", .text)
                t.column("audioBytes", .integer)
                t.column("audioSha256", .text)
                t.column("audioDurationMs", .integer)
                t.column("transcriptText", .text)
                t.column("transcriptProvider", .text)
                t.column("transcriptFinality", .text)
                t.column("targetKind", .text)
                t.column("targetSessionId", .text)
                t.column("targetPid", .integer)
                t.column("targetTty", .text)
                t.column("dispatchAttempts", .integer).notNull().defaults(to: 0)
                t.column("lastDispatchAtMs", .integer)
                t.column("lastError", .text)
                t.column("confirmedAtMs", .integer)
                t.column("discardedReason", .text)
            }
            try db.create(index: "idx_utterances_status", on: "utterances", columns: ["status"])
        }

        // Headless runs are machine-driven: `claude -p` from launchd or cron. There
        // is no tab to open and no session to answer, and because every run gets a
        // NEW session id, supersession cannot collapse them either — a daily job
        // adds one more near-identical unread row every day.
        //
        // The signal is the hook's own controlling terminal, which is inherited by
        // children and severed by setsid. Measured both ways rather than reasoned
        // about: a real `claude -p` run records "??", the same hook under a pty
        // records "ttys147". Nullable on purpose, so rows written before this
        // shipped are unknown rather than assumed headless.
        m.registerMigration("v2_event_tty") { db in
            try db.alter(table: "events") { t in t.add(column: "tty", .text) }
        }

        // Derived state. The single biggest change in the app's life.
        //
        // Session state was a mutable `status` column written by six paths — intake,
        // supersession, user-typed retirement, dismissal, announcement, and the
        // interrupt handler. They raced and clobbered each other. Fixing individual
        // rules stopped changing the outcome, which is the signal that the model is
        // wrong rather than the rules.
        //
        // Now: events are append-only and never updated. What the user has seen
        // lives in one small cursor per session. Waiting is a query. Supersession
        // stops existing — "superseded" is just "not the latest" — and typing into
        // a session retires nothing, because a user_prompt_submit is simply a later
        // event.
        m.registerMigration("v3_derived_state") { db in
            try db.create(table: "session_cursor") { t in
                t.column("sessionId", .text).primaryKey()
                // Event ids, not timestamps. See the index comment below.
                t.column("heardThrough", .integer)
                t.column("dismissedThrough", .integer)
                // When you heard it, which is what the reply window is about. The
                // event's own timestamp is when the AGENT finished, and those are
                // different questions — the old code used the latter and a reply
                // window therefore expired against hook wall-clock rather than
                // against your attention.
                t.column("heardAtMs", .integer)
            }

            // Carry the old statuses across so nothing already dealt with comes back.
            // `superseded` needs no cursor: it is simply not the latest any more.
            try db.execute(sql: """
                INSERT INTO session_cursor (sessionId, heardThrough)
                SELECT sessionId, max(rowid) FROM events
                WHERE status IN ('announced', 'answered') GROUP BY sessionId
                """)
            try db.execute(sql: """
                INSERT INTO session_cursor (sessionId, dismissedThrough)
                SELECT sessionId, max(rowid) FROM events
                WHERE status = 'dismissed' GROUP BY sessionId
                ON CONFLICT(sessionId) DO UPDATE SET
                    dismissedThrough = excluded.dismissedThrough
                """)

            // Exactly one max(), over a column that cannot tie.
            //
            // SQLite guarantees bare columns come from the max row — but only when
            // the maximum is unique: "If the same minimum or maximum value occurs on
            // two or more rows, then bare values might be selected from any of those
            // rows. The choice is arbitrary." Aggregating on a timestamp therefore
            // returns the WRONG row whenever two hooks fire in the same millisecond,
            // silently flipping the state. rowids cannot tie, so the guarantee
            // becomes total.
            try db.execute(sql: """
                CREATE VIEW latest_per_session AS
                SELECT sessionId, max(rowid) AS latestId, hookEvent, createdAtMs,
                       cwd, tty, promptId, transcriptPath, lastAssistantMessage,
                       notificationMatcher, summaryText
                FROM events GROUP BY sessionId
                """)

            // rowid cannot appear in an index — it is the b-tree key itself, and is
            // carried along for free by any index entry. Indexing sessionId is
            // therefore enough to make the grouping a range scan per session rather
            // than a table scan.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_events_session_latest
                ON events(sessionId, hookEvent, tty)
                """)

            // The v1 index on status has to go first: SQLite refuses to drop a
            // column an index still references.
            try db.execute(sql: "DROP INDEX IF EXISTS idx_events_status")

            // Drop the column so nothing can write it again. Any code still
            // referencing it now fails to build, which is the point.
            try db.alter(table: "events") { $0.drop(column: "status") }
        }

        // Phase 1b: the spoken callsign ("promotions copy"), minted once at the
        // session's first successful summary and FROZEN for the session's
        // lifetime. Its own table rather than a column on events, because it is a
        // fact about the session, not about any one turn — and events are
        // append-only facts that never change.
        m.registerMigration("v4_session_callsign") { db in
            try db.create(table: "session_callsign") { t in
                t.column("sessionId", .text).primaryKey()
                t.column("callsign", .text).notNull()
                t.column("mintedAtMs", .integer).notNull()
            }
        }

        // WS-E groundwork: dogfood counters (attribution errors, terminal
        // drop-backs, spoken-update actionability). Append-only like events;
        // counters are computed by query (`dogfoodCounts`), never stored.
        m.registerMigration("v5_dogfood_event") { db in
            try db.create(table: "dogfood_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("atMs", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("sessionId", .text)
                t.column("note", .text)
            }
            try db.create(index: "idx_dogfood_at", on: "dogfood_event", columns: ["atMs"])
        }

        // The store's first summary table. Briefs lived only in the in-memory
        // PreparedSummaries, so a restart lost every card field (depth-1 amnesia)
        // and the v1 events.summaryText column was never written. A brief is a
        // fact ABOUT one event, so it keys on the event's rowid — the same
        // (session, latestId) identity PreparedSummaries enforces — and one row
        // per event means the table accumulates history as events do.
        //
        // Deliberately the seed schema of the product's retention layer (the
        // argument IR): topic / goal / happened / nextStep / question / risk are
        // the argument's fields, recap / proposal its spoken projection, and
        // callsign / provider / atMs its provenance. Future retention features
        // read THIS table; name new columns in those terms.
        m.registerMigration("v6_briefs") { db in
            try db.create(table: "brief") { t in
                // The events rowid this brief summarizes. INTEGER PRIMARY KEY,
                // so re-generating for the same event replaces (last write wins,
                // exactly as PreparedSummaries.put does in memory).
                t.column("eventRowid", .integer).primaryKey()
                t.column("sessionId", .text).notNull()
                t.column("atMs", .integer).notNull()
                t.column("topic", .text).notNull()
                t.column("goal", .text)
                t.column("happened", .text).notNull()
                t.column("nextStep", .text)
                t.column("question", .text)
                t.column("risk", .text)
                t.column("recap", .text)
                t.column("proposal", .text)
                t.column("callsign", .text)
                t.column("provider", .text).notNull()
            }
            try db.create(index: "idx_brief_session", on: "brief", columns: ["sessionId"])
            try db.create(index: "idx_brief_at", on: "brief", columns: ["atMs"])
        }

        // The ⌃⌃ briefing joins the argument: model-written why-plus-risk,
        // spoken only on request. Nullable by design — old rows fall back to
        // the card fields at composition time.
        m.registerMigration("v7_brief_rationale") { db in
            try db.alter(table: "brief") { t in
                t.add(column: "rationale", .text)
            }
        }

        return m
    }

    /// Emitted as SQL for the shell hook, so the hook can create the schema on a
    /// cold machine without the app having run first.
    public static func bootstrapSQL() throws -> String {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-bootstrap-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try QueueStore(url: tmp)
        return try store.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
                """).joined(separator: ";\n") + ";"
        }
    }

    // MARK: - Writes

    /// Insert an event. Returns nil if it was a duplicate (same session + promptId),
    /// which is the normal outcome for a re-fired hook.
    @discardableResult
    public func insert(event: QueuedEvent) throws -> QueuedEvent? {
        try dbQueue.write { db in
            do {
                try event.insert(db)
                return event
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                return nil
            }
        }
    }

    /// Retire everything still waiting for a session.
    ///
    /// Used for both supersession (a newer turn arrived) and self-answering (the
    /// user typed into that session). Rows are marked, never deleted — knowing
    /// what was skipped is part of the record.
    ///
    /// `includeAnnounced` covers the case that matters for catching up: if you have
    /// since typed into a session, the agent is no longer the last turn there and
    /// the session is not waiting on you, so replaying its summary later would be
    /// describing a conversation you have already moved past.
    @discardableResult
    public func supersedePending(
        sessionId: String, before: Int64? = nil, includeAnnounced: Bool = false
    ) throws -> Int {
        try dbQueue.write { db in
            var pending = EventStatus.pendingAnnouncement.map { $0.rawValue }
            if includeAnnounced { pending.append(EventStatus.announced.rawValue) }
            var sql = """
                UPDATE events SET status = 'superseded'
                WHERE sessionId = ? AND status IN (\(pending.map { _ in "?" }.joined(separator: ",")))
                """
            var arguments: [DatabaseValueConvertible] = [sessionId] + pending
            if let before {
                sql += " AND createdAtMs < ?"
                arguments.append(before)
            }
            // Log which rows were retired and by what rule. This is the one path
            // with no observability, and it is where every "nothing waiting" bug so
            // far has actually happened: rows are retired correctly-looking code
            // and nobody can see which rule did it.
            let doomed = try String.fetchAll(
                db, sql: sql.replacingOccurrences(
                    of: "UPDATE events SET status = 'superseded'", with: "SELECT id FROM events"),
                arguments: StatementArguments(arguments))
            try db.execute(sql: sql, arguments: StatementArguments(arguments))
            if !doomed.isEmpty {
                QueueStore.trace?("superseded \(doomed.map { $0.prefix(8) }.joined(separator: ",")) "
                    + "session=\(sessionId.prefix(8)) before=\(before.map(String.init) ?? "any") "
                    + "includeAnnounced=\(includeAnnounced)")
            }
            return db.changesCount
        }
    }

    public func update(event: QueuedEvent) throws {
        try dbQueue.write { db in try event.update(db) }
    }

    public func update(utterance: Utterance) throws {
        try dbQueue.write { db in try utterance.save(db) }
    }

    // MARK: - Reads

    public func events(status: EventStatus? = nil, limit: Int = 50) throws -> [QueuedEvent] {
        try dbQueue.read { db in
            var request = QueuedEvent.order(Column("createdAtMs").desc).limit(limit)
            if let status {
                request = QueuedEvent
                    .filter(Column("status") == status.rawValue)
                    .order(Column("createdAtMs").desc)
                    .limit(limit)
            }
            return try request.fetchAll(db)
        }
    }

    public func utterances(status: UtteranceStatus? = nil, limit: Int = 50) throws -> [Utterance] {
        try dbQueue.read { db in
            var request = Utterance.order(Column("createdAtMs").desc).limit(limit)
            if let status {
                request = Utterance
                    .filter(Column("status") == status.rawValue)
                    .order(Column("createdAtMs").desc)
                    .limit(limit)
            }
            return try request.fetchAll(db)
        }
    }

    /// How many sessions are waiting to be heard.
    ///
    /// This used to add in utterances stuck mid-flight, which made the badge read
    /// "3 waiting" while there was nothing at all to announce — so tapping did
    /// nothing and the app looked broken. Replies in limbo are a real problem, but
    /// they are a different problem, and a number labelled "waiting" next to a key
    /// that plays announcements has to mean announcements. See `unsentReplyCount`.
    ///
    /// Defined positively, as exactly the rows `nextToAnnounce` would offer. It used
    /// to be everything NOT in a terminal set, which reported 52 when two rows were
    /// actually waiting: `announced` was never terminal, and `superseded` was added
    /// later without anyone remembering to exclude it. A negative filter over an
    /// enum you keep extending grows wrong every time it is extended, silently.
    /// Replies that were recorded and never confirmed as delivered. Surfaced apart
    /// from the waiting count because the action they want is different.
    public func unsentReplyCount() throws -> Int {
        try dbQueue.read { db in
            try Utterance
                .filter(UtteranceStatus.inFlight.map(\.rawValue).contains(Column("status")))
                .fetchCount(db)
        }
    }

    /// Set by the app so retirements explain themselves.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// Sessions waiting on you, newest first.
    ///
    /// The whole model in one query. A session is waiting when its latest event is a
    /// Stop that you have neither heard through nor dismissed. Nothing is stored:
    /// supersession is "not the latest", and typing into a session stops it waiting
    /// because the user_prompt_submit is simply a later event.
    ///
    /// No tty filter. Recording the hook's controlling terminal looked like a way
    /// to spot machine-driven runs, and it is not: a hook spawned by a real
    /// interactive session records "??" just as a `claude -p` run does, because
    /// neither hook process has a terminal of its own. Filtering on it hid live
    /// conversations, which is the one failure that must never happen here. Whether
    /// a session is machine-driven is decided by liveness, in the Coordinator, where
    /// the agents API is available.
    ///
    /// Ordered by rowid, never by timestamp. Wall-clock time is stamped
    /// independently by each short-lived hook process and is not monotonic — Kafka
    /// orders by offset for exactly this reason, and a clock step silently loses the
    /// newer write. rowids are assigned under the writer lock and cannot tie.
    public func waitingSessions(limit: Int = 200) throws -> [WaitingSession] {
        try dbQueue.read { db in
            try WaitingSession.fetchAll(db, sql: """
                SELECT l.sessionId, l.latestId, l.createdAtMs, l.cwd, l.tty,
                       l.promptId, l.transcriptPath, l.lastAssistantMessage,
                       l.notificationMatcher, l.summaryText, l.hookEvent,
                       cs.callsign
                FROM latest_per_session l
                LEFT JOIN session_cursor c ON c.sessionId = l.sessionId
                LEFT JOIN session_callsign cs ON cs.sessionId = l.sessionId
                WHERE l.hookEvent = ?
                  AND l.latestId > max(coalesce(c.heardThrough, 0),
                                       coalesce(c.dismissedThrough, 0))
                ORDER BY l.latestId DESC
                LIMIT ?
                """, arguments: [HookEventKind.stop.rawValue, limit])
        }
    }

    /// How many sessions are waiting. Identical predicate to `waitingSessions`, so
    /// the badge and the keypress can never disagree — they used to, and the badge
    /// read "2 waiting" while nothing could be played.
    public func pendingCount() throws -> Int {
        try waitingSessions().count
    }

    /// Advance a cursor. The only write in the model, and therefore the only thing
    /// that can be wrong, so it says what it did.
    public func advanceCursor(
        sessionId: String, heardThrough: Int64? = nil, dismissedThrough: Int64? = nil
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO session_cursor (sessionId, heardThrough, dismissedThrough, heardAtMs)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(sessionId) DO UPDATE SET
                    heardThrough = max(coalesce(heardThrough, 0), coalesce(excluded.heardThrough, 0)),
                    dismissedThrough = max(coalesce(dismissedThrough, 0), coalesce(excluded.dismissedThrough, 0)),
                    heardAtMs = coalesce(excluded.heardAtMs, heardAtMs)
                """, arguments: [sessionId, heardThrough, dismissedThrough,
                                  heardThrough == nil ? nil
                                      : Int64(Date().timeIntervalSince1970 * 1000)])
        }
        QueueStore.trace?("cursor \(sessionId.prefix(8)) heard=\(heardThrough.map(String.init) ?? "-") "
                          + "dismissed=\(dismissedThrough.map(String.init) ?? "-")")
    }

    /// The session whose cursor was advanced most recently by hearing something,
    /// provided that event is still its latest. One query, no scan over statuses.
    public func mostRecentlyHeard(since cutoffMs: Int64) throws -> WaitingSession? {
        try dbQueue.read { db in
            try WaitingSession.fetchOne(db, sql: """
                SELECT l.sessionId, l.latestId, l.createdAtMs, l.cwd, l.tty,
                       l.promptId, l.transcriptPath, l.lastAssistantMessage,
                       l.notificationMatcher, l.summaryText, l.hookEvent,
                       cs.callsign
                FROM session_cursor c
                JOIN latest_per_session l ON l.sessionId = c.sessionId
                LEFT JOIN session_callsign cs ON cs.sessionId = l.sessionId
                WHERE c.heardThrough IS NOT NULL
                  AND c.heardThrough = l.latestId
                  AND c.heardAtMs >= ?
                ORDER BY c.heardAtMs DESC
                LIMIT 1
                """, arguments: [cutoffMs])
        }
    }

    /// Latest per session regardless of cursors. Used when sending a reply that was
    /// recorded a moment ago: hearing it advanced the cursor, so the session is no
    /// longer "waiting", but it is still exactly the session being answered.
    public func waitingSessionsIncludingHeard(limit: Int = 500) throws -> [WaitingSession] {
        try dbQueue.read { db in
            try WaitingSession.fetchAll(db, sql: """
                SELECT l.sessionId, l.latestId, l.createdAtMs, l.cwd, l.tty,
                       l.promptId, l.transcriptPath, l.lastAssistantMessage,
                       l.notificationMatcher, l.summaryText, l.hookEvent,
                       cs.callsign
                FROM latest_per_session l
                LEFT JOIN session_callsign cs ON cs.sessionId = l.sessionId
                ORDER BY l.latestId DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    /// The session's most recent finished turn, regardless of cursors and
    /// regardless of what came after it.
    ///
    /// This is the "hear it again" query. The waiting query is deliberately strict —
    /// unheard Stops only — but an explicit request from a review page means "read
    /// me this session's last summary", and that stays answerable after you have
    /// heard it, dismissed it, or typed since.
    public func latestStop(for sessionId: String) throws -> WaitingSession? {
        try dbQueue.read { db in
            try WaitingSession.fetchOne(db, sql: """
                SELECT e.sessionId, max(e.rowid) AS latestId, e.createdAtMs, e.cwd,
                       e.tty, e.promptId, e.transcriptPath, e.lastAssistantMessage,
                       e.notificationMatcher, e.summaryText, e.hookEvent,
                       cs.callsign
                FROM events e
                LEFT JOIN session_callsign cs ON cs.sessionId = e.sessionId
                WHERE e.sessionId = ? AND e.hookEvent = ?
                """, arguments: [sessionId, HookEventKind.stop.rawValue])
        }
    }

    public func cursor(for sessionId: String) throws -> SessionCursor? {
        try dbQueue.read { db in try SessionCursor.fetchOne(db, key: sessionId) }
    }

    // MARK: - Callsigns

    public func callsign(for sessionId: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT callsign FROM session_callsign WHERE sessionId = ?",
                arguments: [sessionId])
        }
    }

    /// Mint a callsign. FROZEN: the first write wins for the session's lifetime —
    /// a concurrent mint loses silently and the stored value is returned, so two
    /// racing announcers can never speak two different names for one session.
    @discardableResult
    public func mintCallsign(_ callsign: String, for sessionId: String) throws -> String {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO session_callsign (sessionId, callsign, mintedAtMs)
                VALUES (?, ?, ?) ON CONFLICT(sessionId) DO NOTHING
                """, arguments: [sessionId, callsign,
                                  Int64(Date().timeIntervalSince1970 * 1000)])
            return try String.fetchOne(
                db, sql: "SELECT callsign FROM session_callsign WHERE sessionId = ?",
                arguments: [sessionId]) ?? callsign
        }
    }

    /// The mint-time collision set: callsigns of OTHER sessions with recent
    /// activity. Bounded by recency rather than by the agents API so minting is
    /// deterministic and testable — a session that last spoke two days ago no
    /// longer competes for names.
    public func activeCallsigns(
        excluding sessionId: String, activeWithin: TimeInterval = 48 * 3600
    ) throws -> [String] {
        let cutoff = Int64((Date().timeIntervalSince1970 - activeWithin) * 1000)
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.callsign FROM session_callsign c
                JOIN latest_per_session l ON l.sessionId = c.sessionId
                WHERE c.sessionId != ? AND l.createdAtMs >= ?
                """, arguments: [sessionId, cutoff])
        }
    }


    // MARK: - Briefs (v6 — the retention layer's seed table)

    /// Persist a generated brief for one event. Last write wins for the same
    /// event, mirroring `PreparedSummaries.put` — a re-prepare after an
    /// interrupted announcement replaces rather than duplicates.
    public func saveBrief(
        _ brief: SessionBrief, sessionId: String, eventRowid: Int64,
        provider: String, callsign: String?, at: Date = Date()
    ) throws {
        let row = StoredBrief(
            eventRowid: eventRowid, sessionId: sessionId,
            atMs: Int64(at.timeIntervalSince1970 * 1000),
            topic: brief.topic, goal: brief.goal, happened: brief.happened,
            nextStep: brief.nextStep, question: brief.question, risk: brief.risk,
            rationale: brief.rationale,
            recap: brief.recap, proposal: brief.proposal,
            callsign: callsign, provider: provider)
        try dbQueue.write { db in try row.save(db) }
    }

    /// The brief for one specific event — the read-through the in-memory
    /// PreparedSummaries falls back to after a restart.
    public func storedBrief(sessionId: String, eventRowid: Int64) throws -> StoredBrief? {
        try dbQueue.read { db in
            try StoredBrief
                .filter(Column("eventRowid") == eventRowid)
                .filter(Column("sessionId") == sessionId)
                .fetchOne(db)
        }
    }

    /// Newest first, for the lexicon harvest and future retention reads.
    public func recentBriefs(limit: Int = 400) throws -> [StoredBrief] {
        try dbQueue.read { db in
            try StoredBrief.order(Column("atMs").desc).limit(limit).fetchAll(db)
        }
    }

    // MARK: - Boot reconciliation
    //
    // Runs once at launch. The rule that matters: an utterance that was mid-dispatch
    // when we died is AMBIGUOUS — we cannot know whether the keystrokes landed, and a
    // duplicate injection is worse than a dropped one. Those are never auto-resolved
    // here; they are handed to a verifier that reads the target transcript, and if
    // that is inconclusive, to a human.

    public struct ReconciliationReport: Sendable {
        public var requeuedForTranscription: [String] = []
        public var needsDeliveryCheck: [String] = []
        public var orphanedAudio: [String] = []
        public var missingAudio: [String] = []
    }

    public func reconcileOnBoot() throws -> ReconciliationReport {
        var report = ReconciliationReport()

        try dbQueue.write { db in
            let inFlight = try Utterance
                .filter(UtteranceStatus.inFlight.map(\.rawValue).contains(Column("status")))
                .fetchAll(db)

            for var u in inFlight {
                let audioExists = u.audioPath.map { FileManager.default.fileExists(atPath: $0) } ?? false

                switch u.status {
                case .recorded, .transcribing:
                    if audioExists {
                        // Nothing external was touched. Safe to retry from disk.
                        u.status = .recorded
                        report.requeuedForTranscription.append(u.id)
                    } else {
                        u.status = .discarded
                        u.discardedReason = "audio missing at boot reconciliation"
                        report.missingAudio.append(u.id)
                    }
                    try u.update(db)

                case .transcribed, .ready:
                    // Transcript exists, nothing was injected yet — safe to continue.
                    u.status = .ready
                    try u.update(db)

                case .dispatching, .dispatchedUnconfirmed:
                    // AMBIGUOUS. Do not resend. Hand to the delivery checker, which
                    // scans the target transcript for our exact text before deciding.
                    report.needsDeliveryCheck.append(u.id)

                default:
                    break
                }
            }
        }

        report.orphanedAudio = try orphanedAudioFiles()
        return report
    }

    /// Audio files on disk with no row pointing at them.
    private func orphanedAudioFiles() throws -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.audioDirectory, includingPropertiesForKeys: nil) else { return [] }
        let known = Set(try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT id FROM utterances") })
        return files
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !known.contains($0) }
    }

    // MARK: - Retention
    //
    // Structurally status-aware: the query can only ever select `confirmed` or
    // `discarded`. OpenWhispr's equivalent sweep was status-blind and reaped audio
    // belonging to un-retried failures, leaving a retry button pointing at nothing.
    // Age affects visibility, never deletion.

    @discardableResult
    public func reapAudio(olderThan interval: TimeInterval = 72 * 3600) throws -> Int {
        let cutoff = Int64(Date().addingTimeInterval(-interval).timeIntervalSince1970 * 1000)
        let reapable = UtteranceStatus.reapable.map(\.rawValue)

        let rows: [Utterance] = try dbQueue.read { db in
            try Utterance
                .filter(reapable.contains(Column("status")))
                .filter(Column("createdAtMs") < cutoff)
                .filter(Column("audioPath") != nil)
                .fetchAll(db)
        }

        var deleted = 0
        for var u in rows {
            if let path = u.audioPath, FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
                deleted += 1
            }
            u.audioPath = nil
            try update(utterance: u)
        }
        return deleted
    }
}
