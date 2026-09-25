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
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ["turns": [], "note": "transcript file missing"]
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 400_000
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let raw = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        var turns: [[String: String]] = []
        for line in raw.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            var text = ""
            if let s = message["content"] as? String {
                text = s
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: " ")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { turns.append(["who": type, "text": text]) }
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
}
