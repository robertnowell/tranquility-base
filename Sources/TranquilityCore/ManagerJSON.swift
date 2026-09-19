import Foundation

/// The read side of the hands-free manager: what `tbase … --json` prints.
///
/// The manager (tb-voice, a stdio child of the app) never opens the store
/// itself; the CLI is its one door for reads, the way `tbase send` and `tbase
/// new` are its doors for actions. These are Codable so the shape is a tested
/// contract rather than a pretty-print somebody parses. Everything here is
/// derived from stored briefs and the live probe — no model call, ever.
public enum ManagerJSON {

    public struct Target: Codable, Equatable, Sendable {
        public var sessionId: String
        public var harness: String
        public var pid: Int
        public var status: String?
        public var cwd: String?
        public var project: String
        /// The grid's name for the session, by the grid's own rule
        /// (transcript title, then callsign, then the directory). What the
        /// manager says when it introduces one.
        public var name: String?
        public var enrolled: Bool
        /// The brief's goal for the latest event. The closest thing to a
        /// callsign a stranger understands; the manager introduces sessions by it.
        public var goal: String?
        public var topic: String?
        public var waiting: Bool
    }

    public struct WaitingRow: Codable, Equatable, Sendable {
        public var sessionId: String
        public var project: String
        public var name: String?
        public var topic: String?
        public var goal: String?
        public var eventId: Int64
        public var heard: Bool
    }

    public struct Status: Codable, Equatable, Sendable {
        public var waiting: [WaitingRow]
        public var unannounced: Int
    }

    public struct Rung: Codable, Equatable, Sendable {
        public var kind: String
        public var spoken: String
    }

    public struct Brief: Codable, Equatable, Sendable {
        public var sessionId: String
        public var project: String
        public var eventId: Int64
        public var recap: String?
        public var proposal: String?
        public var goal: String?
        public var findings: String?
        public var solution: String?
        public var why: String?
        /// The ladder as the app would speak it, in order, empties skipped.
        public var rungs: [Rung]
        public var lastAssistantMessage: String?
        /// Where the session's own transcript lives, so a question about the
        /// work can be answered from the record, not only from the brief.
        public var transcriptPath: String?
    }

    // MARK: - Builders

    public static func targets(
        store: QueueStore, live: [LiveSession],
        isEnrolled: (String, String?) -> Bool
    ) -> [Target] {
        let waiting = Set((try? store.waitingSessions().map(\.sessionId)) ?? [])
        return live.sorted { ($0.cwd ?? "") < ($1.cwd ?? "") }.map { s in
            let stop = try? store.latestStop(for: s.sessionId)
            let brief = stop.flatMap { e in
                try? store.storedBrief(sessionId: s.sessionId, eventRowid: e.latestId)
            }
            return Target(
                sessionId: s.sessionId, harness: s.harness, pid: s.pid, status: s.status,
                cwd: s.cwd, project: (s.cwd as NSString?)?.lastPathComponent ?? "",
                name: stop.map { GridAssembler.tabDisplayName(for: $0, live: s) }
                    ?? GridAssembler.tabDisplayName(live: s, callsign: nil),
                enrolled: isEnrolled(s.sessionId, s.cwd),
                goal: brief?.goal, topic: brief?.topic ?? stop?.briefTopic,
                waiting: waiting.contains(s.sessionId))
        }
    }

    public static func status(store: QueueStore) throws -> Status {
        let open = try store.waitingSessions()
        let rows = open.map { w -> WaitingRow in
            let brief = try? store.storedBrief(sessionId: w.sessionId, eventRowid: w.latestId)
            return WaitingRow(
                sessionId: w.sessionId, project: w.projectLabel,
                name: GridAssembler.tabDisplayName(for: w, live: nil),
                topic: w.briefTopic ?? brief?.topic, goal: brief?.goal,
                eventId: w.latestId, heard: w.heard)
        }
        return Status(waiting: rows, unannounced: open.filter { !$0.heard }.count)
    }

    /// The latest brief for a session, with its ladder. Nil when the session has
    /// no stored brief yet (a turn the app has not summarised is not a brief).
    public static func brief(store: QueueStore, sessionId: String) throws -> Brief? {
        guard let stop = try store.latestStop(for: sessionId),
              let stored = try store.storedBrief(sessionId: sessionId, eventRowid: stop.latestId)
        else { return nil }
        let sanitizer = SpokenTextSanitizer()
        let brief = stored.brief
        let spoken = sanitizer.sanitize(brief.spokenText(), allowing: [])
        let announcement = Coordinator.Announcement(
            event: stop, brief: brief, spoken: spoken, via: "manager")
        let rungs = SpokenComposition.ladderRungs(for: announcement, sanitizer: sanitizer)
            .map { Rung(kind: $0.kind.rawValue.lowercased(), spoken: $0.spoken.text) }
        return Brief(
            sessionId: sessionId, project: stop.projectLabel, eventId: stop.latestId,
            recap: brief.recap, proposal: brief.proposal, goal: brief.goal,
            findings: brief.findings, solution: brief.solution, why: brief.rationale,
            rungs: rungs,
            lastAssistantMessage: stop.lastAssistantMessage.map { String($0.prefix(600)) },
            transcriptPath: stop.transcriptPath)
    }

    /// The stored announcement for a session's latest turn, rebuilt from the
    /// brief table with no model call: what the ladder and the `rung` verb read.
    public static func announcement(store: QueueStore, sessionId: String) throws -> Coordinator.Announcement? {
        guard let stop = try store.latestStop(for: sessionId),
              let stored = try store.storedBrief(sessionId: sessionId, eventRowid: stop.latestId)
        else { return nil }
        let brief = stored.brief
        let spoken = SpokenTextSanitizer().sanitize(brief.spokenText(), allowing: [])
        return Coordinator.Announcement(event: stop, brief: brief, spoken: spoken, via: "manager")
    }

    /// One rung by name ("goal", "findings", "solution", "why", "message"), or
    /// nil when that rung is empty for this turn. A ladder is never padded.
    public static func rung(store: QueueStore, sessionId: String, kind: String) throws -> SpokenComposition.LadderRung? {
        guard let announcement = try announcement(store: store, sessionId: sessionId) else { return nil }
        return SpokenComposition.ladderRungs(for: announcement)
            .first { $0.kind.rawValue.lowercased() == kind.lowercased() }
    }

    public static func encode<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
