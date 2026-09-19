import Foundation
import GRDB

extension QueueStore {
    /// Backfill/import seam: the caller must supply the ORIGINAL producer's
    /// identity. Missing provenance is not permission to invent a paid intent.
    /// Once bound, a source cannot change when presentation/session state does.
    public func bindSummarySource(_ source: GatewaySource, eventId: String) throws {
        try dbQueue.write { try Self.bindSummarySource(source, eventId: eventId, db: $0) }
    }

    static func bindSummarySource(_ source: GatewaySource, eventId: String, db: Database) throws {
        guard source.isValid else { throw ManagedSummaryFailure.missingSourceIdentity }
        guard try String.fetchOne(db, sql: "SELECT id FROM events WHERE id=?", arguments: [eventId]) != nil
        else { throw ManagedSummaryFailure.missingSourceIdentity }
        if let data = try Data.fetchOne(db, sql: "SELECT source FROM event_summary_source WHERE eventId=?", arguments: [eventId]) {
            guard try JSONDecoder().decode(GatewaySource.self, from: data) == source
            else { throw ManagedSummaryFailure.sourceIdentityConflict }
            return
        }
        try db.execute(sql: "INSERT INTO event_summary_source(eventId,source) VALUES(?,?)",
                       arguments: [eventId, try GatewayContract.encode(source)])
    }

    public func summarySource(eventRowid: Int64) throws -> GatewaySource? {
        try dbQueue.read { try Self.summarySource(eventRowid: eventRowid, db: $0) }
    }

    private static func summarySource(eventRowid: Int64, db: Database) throws -> GatewaySource? {
        guard let data = try Data.fetchOne(db, sql: """
            SELECT s.source FROM event_summary_source s JOIN events e ON e.id=s.eventId
            WHERE e.rowid=?
            """, arguments: [eventRowid]) else { return nil }
        return try JSONDecoder().decode(GatewaySource.self, from: data)
    }

    /// Content and receipt are a single local cache write/read. The FULL-sync
    /// outbox and Gateway remain the durable operation record; this copy is not
    /// a wallet and its balanceAfter is never a current balance.
    static func saveSummaryReceipt(_ receipt: GatewayReceipt?, brief: StoredBrief, db: Database) throws {
        let old = try Data.fetchOne(db, sql: "SELECT receipt FROM brief_receipt WHERE eventRowid=?",
                                   arguments: [brief.eventRowid])
        guard let receipt else {
            // A generic cache writer cannot silently erase a paid association.
            guard old == nil else { throw ManagedSummaryFailure.invalidResponse }
            return
        }
        try validateSummaryReceipt(receipt, brief: brief, db: db)
        if let old {
            guard try JSONDecoder().decode(GatewayReceipt.self, from: old) == receipt
            else { throw ManagedSummaryFailure.invalidResponse }
        } else {
            try db.execute(sql: "INSERT INTO brief_receipt(eventRowid,receipt) VALUES(?,?)",
                           arguments: [brief.eventRowid, try GatewayContract.encode(receipt)])
        }
    }

    private static func validateSummaryReceipt(_ receipt: GatewayReceipt, brief: StoredBrief, db: Database) throws {
        guard let account = UUID(uuidString: receipt.accountId),
              let source = try summarySource(eventRowid: brief.eventRowid, db: db),
              try String.fetchOne(db, sql: "SELECT sessionId FROM events WHERE rowid=?",
                                  arguments: [brief.eventRowid]) == brief.sessionId
        else { throw ManagedSummaryFailure.invalidResponse }
        try GatewayOperation(version: "1", accountId: receipt.accountId, operationId: receipt.operationId,
                             state: .succeeded, brief: brief.brief, receipt: receipt, error: nil)
            .validate(account: account.uuidString.lowercased(), operation: source.operationId(accountId: account))
    }

    func storedSummary(sessionId: String, eventRowid: Int64) throws -> (brief: StoredBrief, receipt: GatewayReceipt?)? {
        try dbQueue.read { db in
            guard let brief = try StoredBrief.fetchOne(db, sql: "SELECT * FROM brief WHERE sessionId=? AND eventRowid=?",
                                                       arguments: [sessionId, eventRowid]) else { return nil }
            var receipt: GatewayReceipt?
            if let data = try Data.fetchOne(db, sql: "SELECT receipt FROM brief_receipt WHERE eventRowid=?", arguments: [eventRowid]) {
                let decoded = try JSONDecoder().decode(GatewayReceipt.self, from: data)
                try Self.validateSummaryReceipt(decoded, brief: brief, db: db)
                receipt = decoded
            }
            return (brief, receipt)
        }
    }
}
