import Foundation

/// The tools this Mac offers the hands-free manager in wire v1 (hf-3, hf-4).
/// Reads only for now; `send` joins when it goes through the app's own Send
/// (hf-12), and until then the bot keeps using `request:run` for effects.
public enum ManagerTools {
    /// What a manager send came to, as the bot reads it (docs/wire-v1.md).
    public enum SendOutcome: String, Sendable {
        /// Typed into the agent and seen to land.
        case typed
        /// The agent was mid-turn; it goes in when that turn ends.
        case queued
        /// Nothing was typed.
        case notDispatched = "not_dispatched"
        /// Typed, but never seen to land. It may have: never retried.
        case ambiguous

        public init(_ outcome: Coordinator.ReplyOutcome?) {
            switch outcome {
            case .dispatched: self = .typed
            case .queued: self = .queued
            case .dispatchFailed(.verificationTimedOut, _), .duplicateSuppressed: self = .ambiguous
            case .dispatchFailed, .noTarget, .sessionNotReady, .transcriptionFailed, .readyToSend, .none:
                self = .notDispatched
            }
        }
    }

    /// The app's own Send, for the `send` tool: the words, to this agent, with
    /// the developer's tray riding along. Returns how it ended.
    public typealias Sender = @Sendable (_ agent: String, _ text: String) async -> Coordinator.ReplyOutcome?

    public static func standard(tbase: String, ledger: ManagerLedger? = nil,
                                sender: Sender? = nil) -> [ManagerTool] {
        var tools: [ManagerTool] = [
            ManagerTool(name: .agents, deadlineMs: 3000, capBytes: 16 * 1024) { _ in
                try await tbaseJSON(tbase, ["targets", "--json"])
            },
            ManagerTool(name: .waiting, deadlineMs: 3000, capBytes: 16 * 1024) { _ in
                try await tbaseJSON(tbase, ["status", "--json"])
            },
            ManagerTool(name: .brief, deadlineMs: 3000, capBytes: 8 * 1024) { args in
                try await tbaseJSON(tbase, ["brief", try agent(args), "--json"])
            },
            // The agent's own record, which the hosted manager could not read
            // at all: its transcript lives on this Mac and the path it was
            // handed did not exist in the container (hf-4).
            ManagerTool(name: .transcript, deadlineMs: 5000, capBytes: 32 * 1024, keep: .newest) { args in
                let brief = try await tbaseJSON(tbase, ["brief", try agent(args), "--json"])
                let data = (brief as? [String: Any])?["data"] as? [String: Any] ?? brief as? [String: Any]
                guard let path = data?["transcriptPath"] as? String, !path.isEmpty else {
                    throw ManagerToolFailure(.notFound, "that agent has no transcript on this Mac")
                }
                let chars = min(max((args["chars"] as? Int) ?? 7000, 200), 30_000)
                // A question about the start of a long session ("what did I
                // ask you for?") is 100 000 characters before any tail: the
                // manager searches the whole record instead (hf-6).
                if let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    return TranscriptTail.search(path: path, query: query, chars: chars)
                }
                return TranscriptTail.read(path: path, chars: chars)
            },
        ]
        if let sender {
            // Effectful: the host requires an idem key and records it before
            // this runs, so a repeat can never type twice (wire v1).
            tools.append(ManagerTool(name: .send, deadlineMs: 20_000, capBytes: 1024, effectful: true) { args in
                let agent = try agent(args)
                guard let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ManagerToolFailure(.badArgs, "text is required")
                }
                let outcome = SendOutcome(await sender(agent, text))
                return ["outcome": outcome.rawValue]
            })
        }
        if let ledger {
            // What the developer (and the manager, and the agents) said, on
            // this Mac, numbered (hf-5). Newest last; a cut drops the oldest.
            tools.append(ManagerTool(name: .ledger, deadlineMs: 2000, capBytes: 32 * 1024, keep: .newest) { args in
                let lines: [ManagerLedger.Line]
                if let from = args["from"] as? Int {
                    lines = ledger.lines(from: from, to: (args["to"] as? Int) ?? Int.max)
                } else if let last = args["last"] as? Int {
                    lines = ledger.last(min(max(last, 1), 500))
                } else {
                    lines = ledger.sinceLastAction()
                }
                return lines.map { line -> [String: Any] in
                    var out: [String: Any] = ["n": line.n, "t": line.t, "role": line.role.rawValue,
                                              "kind": line.kind.rawValue, "text": line.text]
                    if let speaker = line.speaker { out["speaker"] = speaker }
                    if let target = line.target { out["target"] = target }
                    if let name = line.targetName { out["target_name"] = name }
                    return out
                }
            })
        }
        return tools
    }

    static func agent(_ args: [String: Any]) throws -> String {
        guard let id = args["agent"] as? String, !id.isEmpty else {
            throw ManagerToolFailure(.badArgs, "agent is required")
        }
        return id
    }

    static func tbaseJSON(_ tbase: String, _ args: [String]) async throws -> Any {
        let (code, out) = try await ManagerCommand.run(tbase, args)
        guard code == 0 else { throw ManagerToolFailure(.refused, "tbase \(args.first ?? "") exited \(code): \(out.suffix(200))") }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8), options: [.fragmentsAllowed]) else {
            throw ManagerToolFailure(.internal, "tbase \(args.first ?? "") did not print JSON")
        }
        return obj
    }
}

/// A subprocess that dies with its caller: cancelled means terminated, so a
/// deadline is a real deadline and not a promise the process ignores.
public enum ManagerCommand {
    public static func run(_ path: String, _ args: [String]) async throws -> (code: Int, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in buffer.append(h.availableData) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(code: Int, out: String), Error>) in
                p.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    if Task.isCancelled || buffer.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(returning: (Int(proc.terminationStatus), buffer.text))
                    }
                }
                do { try p.run() } catch {
                    p.terminationHandler = nil
                    cont.resume(throwing: ManagerToolFailure(.internal, "could not run \(path): \(error)"))
                }
            }
        } onCancel: {
            buffer.cancelled = true
            if p.isRunning { p.terminate() }
        }
    }

    final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var _cancelled = false
        var cancelled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _cancelled }
            set { lock.lock(); _cancelled = newValue; lock.unlock() }
        }
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}

/// The end of an agent's transcript as text turns, newest last: what it and its
/// supervisor actually said. The same reading the local manager does in
/// Brain.transcript_tail, done where the file is.
public enum TranscriptTail {
    public static func read(path: String, chars: Int) -> [String: Any] {
        guard let turns = turns(path: path, window: 400_000) else {
            return ["turns": [], "note": "transcript file missing"]
        }
        // Newest last, whole turns, within the budget.
        var kept: [[String: String]] = []
        var used = 0
        for t in turns.reversed() {
            let n = t["text"]?.count ?? 0
            if used + n > chars, !kept.isEmpty { break }
            kept.insert(t, at: 0)
            used += n
        }
        return ["turns": kept, "total_turns": turns.count]
    }

    /// The turns anywhere in the transcript that share the most words with
    /// `query`, in the order they were said, within the budget. Each is cut
    /// to the stretch around its first match. Words under three letters do
    /// not count.
    public static func search(path: String, query: String, chars: Int) -> [String: Any] {
        guard let turns = turns(path: path, window: nil) else {
            return ["turns": [], "note": "transcript file missing"]
        }
        let words = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count >= 3 })
        guard !words.isEmpty else { return ["turns": [], "total_turns": turns.count, "note": "no words to search for"] }
        var scored: [(index: Int, score: Int)] = []
        for (i, t) in turns.enumerated() {
            let text = (t["text"] ?? "").lowercased()
            let score = words.filter { text.contains($0) }.count
            if score > 0 { scored.append((i, score)) }
        }
        // Best first, the later of two equals first; then kept in the order said.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index > $1.index }
        let per = 1_500
        var picked: [(Int, [String: String])] = []
        var used = 0
        for hit in scored {
            var t = turns[hit.index]
            let text = t["text"] ?? ""
            if text.count > per {
                let lower = text.lowercased()
                let first = words.compactMap { lower.range(of: $0)?.lowerBound }.min() ?? lower.startIndex
                let offset = max(0, lower.distance(from: lower.startIndex, to: first) - per / 3)
                let start = text.index(text.startIndex, offsetBy: offset)
                let end = text.index(start, offsetBy: min(per, text.distance(from: start, to: text.endIndex)))
                t["text"] = (offset > 0 ? "…" : "") + String(text[start..<end]) + (end < text.endIndex ? "…" : "")
            }
            let n = t["text"]?.count ?? 0
            if used + n > chars, !picked.isEmpty { break }
            t["turn"] = String(hit.index + 1)
            picked.append((hit.index, t))
            used += n
        }
        return ["turns": picked.sorted { $0.0 < $1.0 }.map(\.1), "total_turns": turns.count, "matched": scored.count]
    }

    /// Every text turn in the file, oldest first; `window` reads only its last
    /// that many bytes. Nil when the file cannot be opened.
    static func turns(path: String, window: UInt64?) -> [[String: String]]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if let window, size > window { try? handle.seek(toOffset: size - window) } else { try? handle.seek(toOffset: 0) }
        let raw = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        var turns: [[String: String]] = []
        for line in raw.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let (who, content) = spoken(obj) else { continue }
            var text = ""
            if let s = content as? String {
                text = s
            } else if let parts = content as? [[String: Any]] {
                text = parts.compactMap { part -> String? in
                    guard let kind = part["type"] as? String, ["text", "input_text", "output_text"].contains(kind) else { return nil }
                    return part["text"] as? String
                }.joined(separator: " ")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { turns.append(["who": who, "text": text]) }
        }
        return turns
    }

    /// Who spoke and what, for a line that is a spoken turn. Claude Code writes
    /// {type, message}; Codex writes {type: response_item, payload: {type:
    /// message, role, content}}. A Codex session read as empty before this.
    static func spoken(_ obj: [String: Any]) -> (String, Any?)? {
        if let type = obj["type"] as? String, type == "user" || type == "assistant" {
            return (type, (obj["message"] as? [String: Any])?["content"])
        }
        if obj["type"] as? String == "response_item", let payload = obj["payload"] as? [String: Any],
           payload["type"] as? String == "message", let role = payload["role"] as? String,
           role == "user" || role == "assistant" {
            return (role, payload["content"])
        }
        return nil
    }
}
