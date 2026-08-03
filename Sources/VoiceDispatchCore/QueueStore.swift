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
            try db.execute(sql: sql, arguments: StatementArguments(arguments))
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

    public func pendingCount() throws -> Int {
        try dbQueue.read { db in
            let pending = EventStatus.pendingAnnouncement.map(\.rawValue)
            let events = try QueuedEvent
                .filter(pending.contains(Column("status")))
                .fetchCount(db)
            return events
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
