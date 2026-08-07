import Foundation
import GRDB

/// Drains the hook's append-only spool into SQLite.
///
/// The hook cannot afford to take a database lock — it runs inside a live Claude Code
/// turn, and dozens of sessions can finish at the same instant. So it appends one JSON
/// line and exits. This type is the other half: it moves those lines into the queue,
/// applies dedupe, and truncates the spool only after the rows are committed.
public struct SpoolDrainer: Sendable {
    public let store: QueueStore
    public let spoolURL: URL

    public init(store: QueueStore, spoolURL: URL? = nil) {
        self.store = store
        self.spoolURL = spoolURL ?? QueueStore.supportDirectory.appendingPathComponent("spool.jsonl")
    }

    public struct DrainResult: Sendable {
        public var inserted: Int = 0
        public var duplicates: Int = 0
        public var malformed: Int = 0
        /// Rows retired without being spoken: superseded by a newer turn, or
        /// answered by the user typing into that session.
        public var retired: Int = 0
    }

    /// Move every spooled line into the queue. Safe to call repeatedly.
    ///
    /// Ordering matters: rows are committed *before* the spool is truncated, so a
    /// crash mid-drain replays lines rather than losing them. Replay is harmless
    /// because inserts carry an explicit id and dedupe on (sessionId, promptId).
    @discardableResult
    public func drain() throws -> DrainResult {
        var result = DrainResult()

        guard FileManager.default.fileExists(atPath: spoolURL.path) else { return result }

        // Rotate first: the hook keeps appending to a fresh spool while we work,
        // so nothing arriving mid-drain is lost or double-read.
        let workingURL = spoolURL.appendingPathExtension("draining")
        if FileManager.default.fileExists(atPath: workingURL.path) {
            // A previous drain died before cleanup. Its contents still need replaying —
            // append what's pending onto it rather than clobbering.
            if let pending = try? Data(contentsOf: spoolURL), !pending.isEmpty {
                let handle = try FileHandle(forWritingTo: workingURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: pending)
                try handle.close()
            }
            try? FileManager.default.removeItem(at: spoolURL)
        } else {
            try FileManager.default.moveItem(at: spoolURL, to: workingURL)
        }

        let text = (try? String(contentsOf: workingURL, encoding: .utf8)) ?? ""
        let decoder = JSONDecoder()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else { result.malformed += 1; continue }
            guard let record = try? decoder.decode(SpoolRecord.self, from: data) else {
                result.malformed += 1
                continue
            }
            let event = record.toEvent()

            // Every event is stored, including user_prompt_submit and the turns it
            // used to retire. Retirement was the bug: typing your next message
            // deleted the reply you were about to hear, because the rule looked at
            // the container rather than at the order of events. Gmail gets this
            // right by never annotating the container — "if messages are added to a
            // thread after you add a label, the new messages don't inherit the
            // existing label" — so a new arrival is unread again with no logic and
            // no write. Same here: a later event simply wins.

            if try store.insert(event: event) != nil {
                result.inserted += 1
            } else {
                result.duplicates += 1
            }
        }

        // Only now is it safe to drop the working file.
        try? FileManager.default.removeItem(at: workingURL)
        return result
    }

    /// Wire format written by `hooks/tbase-hook.sh`.
    struct SpoolRecord: Decodable {
        var id: String
        var createdAtMs: Int64
        var hookEvent: String
        var sessionId: String
        var promptId: String?
        var cwd: String?
        var transcriptPath: String?
        var lastAssistantMessage: String?
        var notificationMatcher: String?
        var tty: String?

        func toEvent() -> QueuedEvent {
            QueuedEvent(
                id: id,
                createdAtMs: createdAtMs,
                hookEvent: HookEventKind(rawValue: hookEvent) ?? .stop,
                sessionId: sessionId,
                promptId: promptId,
                cwd: cwd,
                transcriptPath: transcriptPath,
                lastAssistantMessage: lastAssistantMessage,
                notificationMatcher: notificationMatcher,
                tty: tty
            )
        }
    }
}
