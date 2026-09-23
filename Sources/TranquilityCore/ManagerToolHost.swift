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

/// One thing the manager may ask this Mac to do.
public struct ManagerTool: Sendable {
    public enum Keep: Sendable { case newest, oldest }

    public let name: String
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

    public init(name: String, version: Int = 1, deadlineMs: Int, capBytes: Int,
                effectful: Bool = false, keep: Keep = .oldest,
                run: @escaping @Sendable ([String: Any]) async throws -> Any) {
        self.name = name; self.version = version; self.deadlineMs = deadlineMs
        self.capBytes = capBytes; self.effectful = effectful; self.keep = keep; self.run = run
    }
}

/// A tool's refusal, carried back as a coded error rather than a thrown one.
public struct ManagerToolFailure: Error, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public init(_ code: String, _ message: String, retryable: Bool = false) {
        self.code = code; self.message = message; self.retryable = retryable
    }
}

public actor ManagerToolHost {
    public static let protocolVersion = 1
    /// Reads that may run at once; the fifth waits for a slot.
    public static let maxReads = 4
    /// A frame larger than this could hold audio behind it on the same socket.
    public static let maxFrameBytes = 64 * 1024

    private let tools: [String: ManagerTool]
    private let order: [String]
    private let idem: ManagerIdempotency
    private var reads = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var effectBusy = false
    private var effectWaiters: [CheckedContinuation<Void, Never>] = []
    private var running: [String: Task<UncheckedBox<[String: Any]>, Never>] = [:]
    /// Most reads seen in flight at once (for tests and the log).
    public private(set) var peakReads = 0

    public init(tools: [ManagerTool], idempotency: ManagerIdempotency = ManagerIdempotency()) {
        var map: [String: ManagerTool] = [:]
        for t in tools { map[t.name] = t }
        self.tools = map
        self.order = tools.map(\.name)
        self.idem = idempotency
    }

    /// The first frame on every connection: what this Mac offers.
    public func hello(appVersion: String) -> Data {
        Self.encode(["wire": "hello", "protocol": Self.protocolVersion, "app_version": appVersion,
                     "tools": order.compactMap { tools[$0] }.map { ["name": $0.name, "version": $0.version] }])
    }

    /// Whether a text frame from the bot is wire v1 (and so belongs here).
    public nonisolated static func isWire(_ json: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: json) as? [String: Any])?["wire"] is String
    }

    /// A `wire` frame from the bot, as JSON. Returns the frame to send back, or nil.
    public func handle(_ json: Data) async -> Data? {
        guard let frame = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        switch frame["wire"] as? String {
        case "call":
            guard let id = frame["id"] as? String else { return nil }
            let box = UncheckedBox(frame)
            let task = Task { UncheckedBox(await self.call(id: id, frame: box.value)) }
            running[id] = task
            let result = await task.value.value
            running[id] = nil
            return Self.encode(result)
        case "cancel":
            if let id = frame["id"] as? String { running[id]?.cancel() }
            return nil
        default:
            return nil
        }
    }

    // MARK: - one call

    private func call(id: String, frame: [String: Any]) async -> [String: Any] {
        guard let name = frame["tool"] as? String, let tool = tools[name] else {
            return Self.failure(id, ManagerToolFailure("unknown_tool", "no tool \(frame["tool"] ?? "?") on this Mac"))
        }
        let args = frame["args"] as? [String: Any] ?? [:]
        let asked = (frame["deadline_ms"] as? Int) ?? tool.deadlineMs
        let deadline = max(1, min(asked, tool.deadlineMs))

        if tool.effectful {
            guard let key = frame["idem"] as? String, !key.isEmpty else {
                return Self.failure(id, ManagerToolFailure("bad_args", "\(name) changes something; it needs an idem key"))
            }
            // Recorded before the work: a repeat, even one that arrives while
            // the first is still running, returns what is known and never runs
            // the tool a second time.
            switch idem.begin(key) {
            case .done(let data): return ["wire": "result", "id": id, "ok": true, "data": data, "repeat": true]
            case .started: return Self.failure(id, ManagerToolFailure("in_progress", "\(name) with this idem already started; its outcome is not known yet"))
            case .fresh: break
            }
            await acquireEffect()
            let out = await run(tool, args: args, id: id, deadlineMs: deadline)
            releaseEffect()
            if (out["ok"] as? Bool) == true {
                idem.finish(key, data: out["data"] ?? NSNull())
            } else if (out["error"] as? [String: Any])?["code"] as? String == "timeout" {
                // It may have happened. Leave the key started: a repeat says
                // "not known", never runs it again.
            } else {
                idem.forget(key)  // refused before anything happened: a retry is safe
            }
            return out
        }
        await acquireRead()
        let out = await run(tool, args: args, id: id, deadlineMs: deadline)
        releaseRead()
        return out
    }

    private func run(_ tool: ManagerTool, args: [String: Any], id: String, deadlineMs: Int) async -> [String: Any] {
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
            return Self.capped(id: id, data: box.value, tool: tool)
        case .failure(let error):
            if fired.value {
                return Self.failure(id, ManagerToolFailure("timeout", "\(tool.name) passed its \(deadlineMs) ms deadline",
                                                           retryable: !tool.effectful))
            }
            if Task.isCancelled {
                return Self.failure(id, ManagerToolFailure("cancelled", "the manager cancelled this call"))
            }
            if let f = error as? ManagerToolFailure { return Self.failure(id, f) }
            return Self.failure(id, ManagerToolFailure("internal", "\(error)"))
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

    static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(#"{"wire":"result","ok":false}"#.utf8)
    }

    static func failure(_ id: String, _ f: ManagerToolFailure) -> [String: Any] {
        ["wire": "result", "id": id, "ok": false,
         "error": ["code": f.code, "message": f.message, "retryable": f.retryable]]
    }

    /// Under the cap as sent, or cut from the end the tool does not keep and
    /// marked `truncated`. Never silently.
    static func capped(id: String, data: Any, tool: ManagerTool) -> [String: Any] {
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
                return failure(id, ManagerToolFailure("too_large", "\(tool.name) result is over \(cap) bytes and cannot be cut"))
            }
        }
        var out: [String: Any] = ["wire": "result", "id": id, "ok": true, "data": value]
        if truncated { out["truncated"] = true }
        return out
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
