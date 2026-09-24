import Foundation

// Wire v1: the hands-free manager's hands on this Mac (hf-3, tb-voice/docs/wire-v1.md).
//
// Before this the bot sent `request:run` with any `tbase` argv; the app ran it
// with no deadline, inside the socket's receive loop (so nothing else was read
// while it ran), and a send that landed could read as failed and be retried.
// Now the Mac says which tools it offers (`hello`), the bot calls them by name
// (`call`), and each call has a deadline enforced here, a size cap with the
// cut marked, a concurrency class, and for anything that changes the world an
// idempotency key recorded BEFORE the work starts, so a repeat can never type
// twice.
//
// Transport-agnostic: the WebSocket (ManagerSocket) and the WebRTC data channel
// (ManagerPeer) both hand their `wire` frames to one host and send back what it
// returns.

/// The `wire` field of a v1 frame. Parsed once; nothing below compares strings.
public enum ManagerWireKind: String, Sendable {
    case hello, call, result, cancel, event
}

/// The tools wire v1 knows. A name outside this list is refused at the door.
public enum ManagerToolName: String, CaseIterable, Sendable {
    case agents, waiting, brief, transcript, ledger
    /// In the spec, not yet offered: it arrives with Coordinator send (hf-12).
    case send
}

/// Why a call failed, as the bot reads it (docs/wire-v1.md).
public enum ManagerToolErrorCode: String, Sendable {
    case unknownTool = "unknown_tool"
    case badArgs = "bad_args"
    case notFound = "not_found"
    case refused
    case timeout
    case cancelled
    case inProgress = "in_progress"
    case tooLarge = "too_large"
    case `internal`
}

/// One thing the manager may ask this Mac to do.
public struct ManagerTool: Sendable {
    public enum Keep: Sendable { case newest, oldest }

    public let name: ManagerToolName
    public let version: Int
    /// The Mac gives up at this deadline unless the call asks for less.
    public let deadlineMs: Int
    /// A result larger than this is cut, and says so.
    public let capBytes: Int
    /// Changes something outside this process: one at a time, and `idem` required.
    public let effectful: Bool
    /// Which end of a list or text survives a cut.
    public let keep: Keep
    public let run: @Sendable ([String: Any]) async throws -> Any

    public init(name: ManagerToolName, version: Int = 1, deadlineMs: Int, capBytes: Int,
                effectful: Bool = false, keep: Keep = .oldest,
                run: @escaping @Sendable ([String: Any]) async throws -> Any) {
        self.name = name; self.version = version; self.deadlineMs = deadlineMs
        self.capBytes = capBytes; self.effectful = effectful; self.keep = keep; self.run = run
    }
}

/// A tool's refusal, carried back as a coded error rather than a thrown one.
public struct ManagerToolFailure: Error, Sendable {
    public let code: ManagerToolErrorCode
    public let message: String
    public let retryable: Bool
    public init(_ code: ManagerToolErrorCode, _ message: String, retryable: Bool = false) {
        self.code = code; self.message = message; self.retryable = retryable
    }
}

public actor ManagerToolHost {
    public static let protocolVersion = 1
    /// Reads that may run at once; the fifth waits for a slot.
    public static let maxReads = 4
    /// A frame larger than this could hold audio behind it on the same socket.
    public static let maxFrameBytes = 64 * 1024

    private let tools: [ManagerToolName: ManagerTool]
    private let order: [ManagerToolName]
    private let idem: ManagerIdempotency
    private var reads = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var effectBusy = false
    private var effectWaiters: [CheckedContinuation<Void, Never>] = []
    private var running: [String: Task<Outcome, Never>] = [:]
    /// Most reads seen in flight at once (for tests and the log).
    public private(set) var peakReads = 0

    public init(tools: [ManagerTool], idempotency: ManagerIdempotency = ManagerIdempotency()) {
        var map: [ManagerToolName: ManagerTool] = [:]
        for t in tools { map[t.name] = t }
        self.tools = map
        self.order = tools.map(\.name)
        self.idem = idempotency
    }

    /// The first frame on every connection: what this Mac offers.
    public func hello(appVersion: String) -> Data {
        Self.encode(["wire": ManagerWireKind.hello.rawValue, "protocol": Self.protocolVersion, "app_version": appVersion,
                     "tools": order.compactMap { tools[$0] }.map { ["name": $0.name.rawValue, "version": $0.version] }])
    }

    /// Whether a text frame from the bot is wire v1 (and so belongs here).
    public nonisolated static func isWire(_ json: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["wire"] != nil
    }

    /// A `wire` frame from the bot, as JSON. Returns the frame to send back, or nil.
    public func handle(_ json: Data) async -> Data? {
        guard let frame = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        guard let raw = frame["wire"] as? String, let kind = ManagerWireKind(rawValue: raw),
              let id = frame["id"] as? String else { return nil }
        switch kind {
        case .call:
            let box = UncheckedBox(frame)
            let task = Task { await self.call(frame: box.value) }
            running[id] = task
            let outcome = await task.value
            running[id] = nil
            return Self.encode(outcome.frame(id: id))
        case .cancel:
            running[id]?.cancel()
            return nil
        case .hello, .result, .event:
            return nil  // only the bot calls and cancels; these travel the other way
        }
    }

    // MARK: - one call

    private func call(frame: [String: Any]) async -> Outcome {
        guard let raw = frame["tool"] as? String, let name = ManagerToolName(rawValue: raw), let tool = tools[name] else {
            return .failed(ManagerToolFailure(.unknownTool, "no tool \(frame["tool"] ?? "?") on this Mac"))
        }
        let args = frame["args"] as? [String: Any] ?? [:]
        let asked = (frame["deadline_ms"] as? Int) ?? tool.deadlineMs
        let deadline = max(1, min(asked, tool.deadlineMs))

        if tool.effectful {
            guard let key = frame["idem"] as? String, !key.isEmpty else {
                return .failed(ManagerToolFailure(.badArgs, "\(name.rawValue) changes something; it needs an idem key"))
            }
            // Recorded before the work: a repeat, even one that arrives while
            // the first is still running, returns what is known and never runs
            // the tool a second time.
            switch idem.begin(key) {
            case .done(let data): return .repeated(UncheckedBox(data))
            case .started:
                return .failed(ManagerToolFailure(.inProgress, "\(name.rawValue) with this idem already started; its outcome is not known yet"))
            case .fresh: break
            }
            await acquireEffect()
            let outcome = await run(tool, args: args, deadlineMs: deadline)
            releaseEffect()
            switch outcome {
            case .done(let data, _): idem.finish(key, data: data.value)
            case .failed(let f) where f.code == .timeout:
                break  // it may have happened: leave the key started, never run it again
            case .failed, .repeated: idem.forget(key)  // refused before anything happened: a retry is safe
            }
            return outcome
        }
        await acquireRead()
        let outcome = await run(tool, args: args, deadlineMs: deadline)
        releaseRead()
        return outcome
    }

    private func run(_ tool: ManagerTool, args: [String: Any], deadlineMs: Int) async -> Outcome {
        let args = UncheckedBox(args)
        let work = Task.detached { () -> Result<UncheckedBox<Any>, Error> in
            do { return .success(UncheckedBox(try await tool.run(args.value))) } catch { return .failure(error) }
        }
        let fired = DeadlineFlag()
        let timer = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(deadlineMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            fired.set()
            work.cancel()
        }
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        timer.cancel()
        switch outcome {
        case .success(let box):
            // A tool that finished is reported as finished, even past its
            // deadline: for an effectful one that is the truth about the world.
            return Self.capped(box.value, tool: tool)
        case .failure(let error):
            if fired.value {
                return .failed(ManagerToolFailure(.timeout, "\(tool.name.rawValue) passed its \(deadlineMs) ms deadline",
                                                  retryable: !tool.effectful))
            }
            if Task.isCancelled {
                return .failed(ManagerToolFailure(.cancelled, "the manager cancelled this call"))
            }
            if let f = error as? ManagerToolFailure { return .failed(f) }
            return .failed(ManagerToolFailure(.internal, "\(error)"))
        }
    }

    // MARK: - concurrency classes

    private func acquireRead() async {
        if reads < Self.maxReads {
            reads += 1
        } else {
            await withCheckedContinuation { readWaiters.append($0) }  // the releaser hands its slot over
        }
        peakReads = max(peakReads, reads)
    }

    private func releaseRead() {
        if readWaiters.isEmpty { reads -= 1 } else { readWaiters.removeFirst().resume() }
    }

    private func acquireEffect() async {
        if !effectBusy { effectBusy = true; return }
        await withCheckedContinuation { effectWaiters.append($0) }
    }

    private func releaseEffect() {
        if effectWaiters.isEmpty { effectBusy = false } else { effectWaiters.removeFirst().resume() }
    }

    // MARK: - shapes

    /// What a call came to. Encoded to a `result` frame only at the edge.
    enum Outcome: Sendable {
        case done(UncheckedBox<Any>, truncated: Bool)
        case repeated(UncheckedBox<Any>)
        case failed(ManagerToolFailure)

        func frame(id: String) -> [String: Any] {
            var out: [String: Any] = ["wire": ManagerWireKind.result.rawValue, "id": id]
            switch self {
            case .done(let data, let truncated):
                out["ok"] = true; out["data"] = data.value
                if truncated { out["truncated"] = true }
            case .repeated(let data):
                out["ok"] = true; out["data"] = data.value; out["repeat"] = true
            case .failed(let f):
                out["ok"] = false
                out["error"] = ["code": f.code.rawValue, "message": f.message, "retryable": f.retryable]
            }
            return out
        }
    }

    static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj))
            ?? Data(#"{"wire":"result","ok":false,"error":{"code":"internal","message":"unencodable result","retryable":false}}"#.utf8)
    }

    /// Under the cap as sent, or cut from the end the tool does not keep and
    /// marked `truncated`. Never silently.
    static func capped(_ data: Any, tool: ManagerTool) -> Outcome {
        let cap = min(tool.capBytes, maxFrameBytes - 512)
        var value = data
        var truncated = false
        while let size = jsonSize(value), size > cap {
            truncated = true
            if var list = value as? [Any], !list.isEmpty {
                let drop = max(1, list.count / 8)
                if tool.keep == .newest { list.removeFirst(min(drop, list.count)) } else { list.removeLast(min(drop, list.count)) }
                value = list
            } else if let text = value as? String, !text.isEmpty {
                value = cut(text, toBytes: max(0, cap - 64), keep: tool.keep)
                if let s = value as? String, s == text { value = String(text.prefix(text.count / 2)) }
            } else {
                return .failed(ManagerToolFailure(.tooLarge, "\(tool.name.rawValue) result is over \(cap) bytes and cannot be cut"))
            }
        }
        return .done(UncheckedBox(value), truncated: truncated)
    }

    static func cut(_ text: String, toBytes limit: Int, keep: ManagerTool.Keep) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return text }
        let slice = keep == .newest ? Array(bytes.suffix(limit)) : Array(bytes.prefix(limit))
        var s = String(decoding: slice, as: UTF8.self)
        // On a line boundary when there is one.
        if keep == .newest, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        if keep == .oldest, let nl = s.lastIndex(of: "\n") { s = String(s[..<nl]) }
        return s
    }

    static func jsonSize(_ value: Any) -> Int? {
        if let s = value as? String { return s.utf8.count + 2 }
        guard JSONSerialization.isValidJSONObject([value]),
              let d = try? JSONSerialization.data(withJSONObject: [value]) else { return nil }
        return d.count
    }
}

/// What the WebRTC data channel needs on every message it carries. The bot's
/// framework reads `type` on each one and throws away any without it (pipecat
/// smallwebrtc connection.py: `json_message["type"]`), so a wire v1 `hello` or
/// `result` sent bare never arrived: on 24 Sep the Mac said hello and the bot
/// went on using request:run. The field is carriage, not protocol, so the
/// transport stamps it and nothing reads it. "signalling" is reserved.
public enum ManagerDataChannel {
    public static let carriageType = "tb"

    /// The same JSON object with `type` set for the data channel.
    public static func stamped(_ json: Data) -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return json }
        obj["type"] = carriageType
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? json
    }
}

/// Idempotency keys for effectful calls, persisted so a repeat after an app
/// restart still never runs twice. Kept 24 hours.
public final class ManagerIdempotency: @unchecked Sendable {
    public enum Begin { case fresh, started, done(Any) }

    private let url: URL?
    private let lock = NSLock()
    private var entries: [String: [String: Any]] = [:]
    private let keep: TimeInterval = 24 * 3600

    /// `url` nil keeps the record in memory only (tests).
    public init(url: URL? = nil) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: [String: Any]] {
            entries = obj
        }
    }

    public func begin(_ key: String) -> Begin {
        lock.lock(); defer { lock.unlock() }
        prune()
        if let e = entries[key] {
            if e["state"] as? String == "done" { return .done(e["data"] ?? NSNull()) }
            return .started
        }
        entries[key] = ["state": "started", "at": Date().timeIntervalSince1970]
        save()
        return .fresh
    }

    public func finish(_ key: String, data: Any) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = ["state": "done", "at": Date().timeIntervalSince1970, "data": data]
        save()
    }

    public func forget(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = nil
        save()
    }

    private func prune() {
        let now = Date().timeIntervalSince1970
        entries = entries.filter { now - (($0.value["at"] as? Double) ?? 0) < keep }
    }

    private func save() {
        guard let url, JSONSerialization.isValidJSONObject(entries),
              let d = try? JSONSerialization.data(withJSONObject: entries) else { return }
        try? d.write(to: url, options: .atomic)
    }
}

final class DeadlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}

/// Values the JSON layer hands around are not Sendable by type; these are only
/// ever read after the hand-off.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
