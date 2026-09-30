import Foundation

/// The read side of the hands-free manager: what `tbase … --json` prints.
///
/// The manager (tb-voice, hosted) never opens the store itself; the app's
/// wire v1 tools answer its reads from these, through the CLI. These are Codable so the shape is a tested
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
        /// The project folder the user filed it in on the grid, if any.
        public var folder: String? = nil
    }

    public struct WaitingRow: Codable, Equatable, Sendable {
        public var sessionId: String
        public var project: String
        public var name: String?
        public var topic: String?
        public var goal: String?
        public var eventId: Int64
        public var heard: Bool
        /// Where the row sits on the panel, top to bottom from 0; nil when the
        /// panel does not show it. The hands-free manager orders by this.
        public var gridIndex: Int? = nil
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
        isEnrolled: (String, String?) -> Bool,
        book: ProjectBook = ProjectStore.shared.current,
        origin: (String) -> String = SessionLineage.lastKnownOrigin
    ) -> [Target] {
        let open = (try? store.waitingSessions()) ?? []
        let waiting = Set(open.map(\.sessionId))
        // Newest turn first within the asking band, which is what the grid
        // means by recency. `latestId` is monotonic, so it is the same order
        // `SessionRow.quietRowsLast` gets from `lastActivity`.
        let askedAt = Dictionary(open.map { ($0.sessionId, $0.latestId) },
                                 uniquingKeysWith: max)
        let sorted = live.sorted { a, b in
            let (x, y) = (Self.gridBand(a, waiting: waiting), Self.gridBand(b, waiting: waiting))
            if x != y { return x < y }
            if x == 0 {
                let (i, j) = (askedAt[a.sessionId] ?? 0, askedAt[b.sessionId] ?? 0)
                if i != j { return i > j }
            }
            return (a.cwd ?? "") < (b.cwd ?? "")
        }
        // The panel's folder order (ruling-project-folders, rules 1 and 3):
        // folders first in the user's order, loose sessions last. Within each
        // group the order above stands.
        func folderOf(_ id: String) -> ProjectBook.Folder? { book.folder(of: id, origin: origin) }
        let folderOrder = book.folders.map(\.id)
        let grouped = folderOrder.flatMap { id in sorted.filter { folderOf($0.sessionId)?.id == id } }
            + sorted.filter { folderOf($0.sessionId) == nil }
        return grouped.map { s in
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
                waiting: waiting.contains(s.sessionId),
                folder: folderOf(s.sessionId)?.name)
        }
    }

    /// The order the grid DRAWS these rows in. **Not the invite queue.**
    ///
    /// That distinction is the whole of a bug shipped and withdrawn on the
    /// same night. Ruled 27 Sep: "it should be the same rules as for the grid
    /// today, bring next agent." I read that as `SessionRow.quietRowsLast`,
    /// which is how the grid paints five bands including the blue one, and
    /// pointed the manager's invite at it. Hours later it invited a blue lamp
    /// with green rows sitting in the grid, and Robert was exact about why:
    /// "Control-Option from the grid doesn't open Blue Lamp sessions."
    ///
    /// He is right, and the authority was never this function. ⌃⌥ is
    /// `announceNext`, which walks the WAITING rows and nothing else. Drawing
    /// a session and announcing it are different acts, and only one of them is
    /// what "bring the next agent" means. `manager.py:_next_session` reads the
    /// waiting list directly now and never consults this order.
    ///
    /// It stays because the alternative here was alphabetical by working
    /// directory, which is not an order anybody wants a fleet listed in. It
    /// sorts what `tbase targets` lists. It decides nothing about who speaks.
    static func gridBand(_ s: LiveSession, waiting: Set<String>) -> Int {
        if waiting.contains(s.sessionId) { return 0 }   // asks for you
        if s.status == "busy" { return 1 }              // working on its own
        return 2                                        // merely alive
    }

    /// The waiting rows the manager can actually act on: the ones whose session
    /// is still alive.
    ///
    /// `live` is not optional and not defaulted, because the day it defaulted
    /// to "everything" is the day this shipped 200 rows. The store keeps a
    /// waiting row long after its session has gone -- 186 of those 200 on
    /// 28 Sep, against 21 live sessions and 14 that were really waiting. At
    /// 29,160 bytes the answer was over the data channel's 16 KB ceiling, so
    /// the app refused to send it at all:
    ///
    ///     {'wire': 'result', 'ok': False, 'error': {'code': 'too_large',
    ///      'message': 'waiting result is over 16384 bytes and cannot be cut'}}
    ///
    /// and the manager, receiving nothing, told Robert nobody was waiting while
    /// the grid in front of him showed a column of green. The fleet was never
    /// large; the history was.
    ///
    /// Filtering here rather than in the manager is the point: the bot cannot
    /// filter a payload that never arrives. `Manager._live_waiting` has done
    /// this same intersection client-side since it was written, for the same
    /// stated reason -- "the store keeps rows for sessions long gone; those are
    /// not 'waiting on you' in any sense worth saying aloud". It was right, and
    /// it was on the wrong side of the wire.
    public static func status(store: QueueStore, live: Set<String>,
                              gridOrder: [String] = GridOrder.load()) throws -> Status {
        // In the panel's order, top to bottom (GridOrder, ruled 29 Sep 2026).
        let open = GridOrder.rank(try store.waitingSessions().filter { live.contains($0.sessionId) },
                                  id: \.sessionId, order: gridOrder)
        let position = Dictionary(gridOrder.enumerated().map { ($1, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let rows = open.map { w -> WaitingRow in
            let brief = try? store.storedBrief(sessionId: w.sessionId, eventRowid: w.latestId)
            return WaitingRow(
                sessionId: w.sessionId, project: w.projectLabel,
                name: GridAssembler.tabDisplayName(for: w, live: nil),
                topic: w.briefTopic ?? brief?.topic, goal: brief?.goal,
                eventId: w.latestId, heard: w.heard, gridIndex: position[w.sessionId])
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
