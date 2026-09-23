import Foundation

/// Everything said in hands-free, on this Mac, in order, whole: the ledger
/// (hf-5). It is the record the rest of the redesign reads from. A send picks
/// a span of its lines and the app copies them word for word (hf-8), the
/// classifier sees the lines since the last action (hf-7), and the notes page
/// is derived from it (hf-18).
///
/// The bot emits a `said` line for every line of its exchange (hf-20): the
/// developer's, the manager's, an agent's, and what the manager typed. The app
/// appends each one here as a node `{n, t, who, text, kind, session}`. `n` is
/// this Mac's own sequence, continuous across sessions and restarts (the bot's
/// `said.n` restarts per session). Anything derived cites `n`, never copies text.
///
/// One writer: the manager line loop, one session at a time. Stored as JSON
/// lines in the support directory; a file over `maxBytes` is rotated aside and
/// numbering carries on.
public final class ManagerLedger: @unchecked Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public let n: Int
        public let t: Double
        public let who: String
        public let text: String
        /// The bot's status for the line: `silent` (said, not addressed),
        /// `acted` (a command, or something the manager did), `dictated`,
        /// `spoken` (said aloud by the manager or an agent).
        public let kind: String
        /// The hosted session it was said in.
        public let session: String?

        /// A line the developer said to the manager rather than about the work:
        /// never part of what gets sent (hf-8).
        public var isCommand: Bool { who == "you" && kind == "acted" }
        /// Something the manager did, such as typing into an agent.
        public var isAction: Bool { who != "you" && kind == "acted" }
    }

    public let directory: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private var next: Int

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

    /// Append the line if `json` is a `said` event; returns the stored node.
    @discardableResult
    public func append(said json: Data, session: String?) -> Line? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              obj["event"] as? String == "said",
              let text = obj["text"] as? String, !text.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let line = Line(n: next, t: (obj["t"] as? Double) ?? Date().timeIntervalSince1970,
                        who: (obj["who"] as? String) ?? "?", text: text,
                        kind: (obj["status"] as? String) ?? "said", session: session)
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

    private let writer = DispatchQueue(label: "manager.ledger")

    /// For the app's line loop, which runs on the main actor: cheap to call
    /// on every line (only `said` lines go further), written in order on a
    /// serial queue so the file never costs a frame.
    public func enqueue(line json: Data, session: String?) {
        // Only a cheap sieve; append() parses and checks the event exactly.
        // Not `"event":"said"`: the WebRTC path writes `"event": "said"`
        // (a space), and a sieve on the compact form dropped every line of
        // the transport the app actually uses.
        guard json.range(of: Data(#""said""#.utf8)) != nil else { return }
        writer.async { [self] in _ = append(said: json, session: session) }
    }

    /// Waits for every enqueued line to be written (tests, shutdown).
    public func flush() { writer.sync {} }

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
