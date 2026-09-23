import Foundation

/// Who said a line (hf-26). Parsed from the bot's `said` event; an unknown
/// value makes the line unparseable, which is counted, never guessed.
public enum ManagerRole: String, Codable, Sendable {
    case user, manager, agent
}

/// What a line is (hf-26).
public enum ManagerLineKind: String, Codable, Sendable {
    /// The developer said it, not to the manager.
    case talk
    /// The developer said it to the manager: never part of what gets sent.
    case command
    /// The developer's words into an open message.
    case dictation
    /// Said aloud by the manager or an agent.
    case spoken
    /// Something the manager did, such as typing into an agent.
    case action
}

/// Everything said in hands-free, on this Mac, in order, whole: the ledger
/// (hf-5). It is the record the rest of the redesign reads from. A send picks
/// a span of its lines and the app copies them word for word (hf-8), the
/// classifier sees the lines since the last action (hf-7), and the notes page
/// is derived from it (hf-18).
///
/// Every line the app receives from the bot is decoded here, off the main
/// actor, through the same typed event boundary the orb uses
/// (`ManagerEvent.Kind`); a `said` event becomes a typed `Line`. There is no
/// text sieve: the first version picked lines out with a byte match that the
/// WebRTC path's spacing defeated. `n` is this Mac's own sequence, continuous
/// across sessions, relaunches and rotation. Anything derived cites `n`.
public final class ManagerLedger: @unchecked Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public let n: Int
        public let t: Double
        public let role: ManagerRole
        public let kind: ManagerLineKind
        public let text: String
        /// An agent's display name; nil for the developer and the manager.
        public let speaker: String?
        /// For an action: the agent it went to, by session id and by name.
        public let target: String?
        public let targetName: String?
        /// The hosted session it was said in.
        public let session: String?

        public var isCommand: Bool { role == .user && kind == .command }
        public var isAction: Bool { kind == .action }
    }

    /// The `said` event as the bot sends it.
    struct Said: Decodable {
        let event: ManagerEvent.Kind
        let t: Double?
        let role: ManagerRole
        let kind: ManagerLineKind
        let text: String
        let speaker: String?
        let target: String?
        let targetName: String?

        enum CodingKeys: String, CodingKey {
            case event, t, role, kind, text, speaker, target
            case targetName = "target_name"
        }
    }

    /// Just enough of any line to know what event it is.
    private struct Head: Decodable {
        let event: ManagerEvent.Kind
    }

    public let directory: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private var next: Int
    private var unparsedCount = 0
    private let writer = DispatchQueue(label: "manager.ledger")

    /// Called (on the writer queue) when a `said` event cannot be decoded, so
    /// the app can log it. A lost line is never silent.
    public var onUnparsed: (@Sendable (String) -> Void)?

    public var file: URL { directory.appendingPathComponent("ledger.jsonl") }
    private var previous: URL { directory.appendingPathComponent("ledger.1.jsonl") }

    public init(directory: URL, maxBytes: Int = 8 * 1024 * 1024) {
        self.directory = directory
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let last = Self.readLines(directory.appendingPathComponent("ledger.jsonl")).last
            ?? Self.readLines(directory.appendingPathComponent("ledger.1.jsonl")).last
        next = (last?.n ?? 0) + 1
    }

    /// For the app's line loop on the main actor: hands every line to a serial
    /// queue, where it is decoded and, if it is `said`, written in order.
    public func enqueue(line json: Data, session: String?) {
        writer.async { [self] in _ = record(json, session: session) }
    }

    /// Waits for every enqueued line to be handled (tests, shutdown).
    public func flush() { writer.sync {} }

    /// `said` events that could not be decoded, since launch.
    public var unparsed: Int { lock.lock(); defer { lock.unlock() }; return unparsedCount }

    /// Decode one line from the bot; store it if it is `said`. Returns the
    /// stored line, or nil for any other event.
    @discardableResult
    public func record(_ json: Data, session: String?) -> Line? {
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(Head.self, from: json), head.event == .said else { return nil }
        let said: Said
        do {
            said = try decoder.decode(Said.self, from: json)
        } catch {
            lock.lock(); unparsedCount += 1; lock.unlock()
            onUnparsed?("ledger: a said line did not decode (\(error)): \(String(decoding: json.prefix(160), as: UTF8.self))")
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        let line = Line(n: next, t: said.t ?? Date().timeIntervalSince1970, role: said.role, kind: said.kind,
                        text: said.text, speaker: said.speaker, target: said.target,
                        targetName: said.targetName, session: session)
        guard var data = try? JSONEncoder().encode(line) else { return nil }
        data.append(0x0A)
        rotateIfNeeded(adding: data.count)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: file)
        }
        next += 1
        return line
    }

    /// Lines `from...to`, inclusive, in order.
    public func lines(from: Int, to: Int) -> [Line] {
        all().filter { $0.n >= from && $0.n <= to }
    }

    /// The last `count` lines.
    public func last(_ count: Int) -> [Line] {
        Array(all().suffix(max(0, count)))
    }

    /// Everything after the manager last acted (last typed into an agent, say):
    /// what a send could draw from, or the classifier's context (hf-7, hf-8).
    public func sinceLastAction(limit: Int = 200) -> [Line] {
        let lines = all()
        let start = (lines.lastIndex(where: \.isAction).map { $0 + 1 }) ?? 0
        return Array(lines[start...].suffix(limit))
    }

    private func all() -> [Line] {
        lock.lock(); defer { lock.unlock() }
        return Self.readLines(previous) + Self.readLines(file)
    }

    private func rotateIfNeeded(adding: Int) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size + adding > maxBytes, size > 0 else { return }
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: file, to: previous)
    }

    static func readLines(_ url: URL) -> [Line] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Line.self, from: Data($0)) }
    }
}
