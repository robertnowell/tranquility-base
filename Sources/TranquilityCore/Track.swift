import CryptoKit
import Foundation

/// Product events: what people do with the panel, as facts and numbers.
///
/// Ruled 6 Sep 2026: every critical action, every chord with the face it
/// landed in and what the app decided, every panel face change, every lamp
/// change per agent, the full agent and capture lifecycles. The question
/// it exists to answer is whether people keep using this and where they
/// stop, which is not answerable from failures alone.
///
/// Never text. That is not a scrubbing rule here, it is a type: a property
/// value is a token from a fixed vocabulary, a number, a bool, or a hash.
/// There is no case for free text, and a token that does not look like a
/// token (letters, digits, `_ . : -`, at most 48 characters) is refused at
/// the door and logged, so a transcript cannot ride even by mistake.
///
/// Identity is the same random install id the failure record uses. An
/// agent, a directory, anything that names a thing on the user's machine,
/// goes through `Track.hash`, which is SHA-256 salted with the install id:
/// stable inside one install so an agent can be followed, meaningless
/// across installs, useless for opening anybody's transcript.
///
/// Same latency discipline as `Failures`: the caller pays a dictionary
/// and an enqueue; encoding, writing and forwarding are off-thread.
public enum TrackValue: Equatable, Sendable {
    case token(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case hash(String)
    /// Words written by the AGENT or by this APP, never by the person.
    ///
    /// Ruled 7 Sep 2026 by Robert, and it is the sharper line: "text coming
    /// from an agent or the app is fine, it's the user's messages that are
    /// privileged." A harness's error, a pane's trust prompt, a notice the
    /// panel showed: all of these are the machine talking about itself, and
    /// they are the most useful thing in the record when a launch stalls on
    /// someone else's desk.
    ///
    /// The door scrubs every one of these through `Scrub.text` (home path to
    /// `~`, emails, API keys and bearer tokens to placeholders) and truncates,
    /// so a call site cannot leak a home directory even by accident. What
    /// still never appears is what the PERSON said: no transcript, no
    /// dictation, no announcement text, and no call site passes one.
    case prose(String)

    /// The longest prose the record keeps. A pane's screen is the longest
    /// thing here and its first two lines are what a reader needs.
    static let proseLimit = 240

    /// The vocabulary shape. Enumerations only.
    static let tokenAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-")

    var isAdmissible: Bool {
        switch self {
        case .token(let s):
            return !s.isEmpty && s.count <= 48 && s.unicodeScalars.allSatisfy { Self.tokenAllowed.contains($0) }
        case .hash(let s):
            return s.count == 16 && s.unicodeScalars.allSatisfy { ("0"..."9").contains(Character(String($0))) || ("a"..."f").contains(Character(String($0))) }
        case .prose(let s):
            return !s.isEmpty
        case .int, .double, .bool:
            return true
        }
    }

    /// Scrubbed and bounded. Applied at the door, so admissibility is a
    /// property of the funnel rather than of every call site.
    var scrubbed: TrackValue {
        guard case .prose(let s) = self else { return self }
        return .prose(String(Scrub.text(s).prefix(TrackValue.proseLimit)))
    }

    /// The token as a String, for callers composing a decision from prose.
    public var tokenString: String {
        if case .token(let t) = self { return t }
        if case .hash(let h) = self { return h }
        if case .prose(let s) = self { return s }
        return "none"
    }

    public var json: Any {
        switch self {
        case .token(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .hash(let h): return h
        case .prose(let s): return s
        }
    }
}

extension TrackValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                      ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .token(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public struct TrackEvent: Equatable, Sendable {
    public var name: String
    public var at: Date
    public var properties: [String: TrackValue]
    public init(name: String, at: Date = Date(), properties: [String: TrackValue]) {
        self.name = name; self.at = at; self.properties = properties
    }
}

public enum Track {
    @TaskLocal public static var captureID: String?
    @TaskLocal public static var attemptID: String?
    nonisolated(unsafe) private static var sequence = 0
    private static let processID = UUID().uuidString.lowercased()
    /// Where events go once wired to a service. Only `attach` writes it (and
    /// `detach` clears it); nil means local only. Called off the caller's
    /// thread.
    ///
    /// One writer, by construction. Until 7 Sep a drill in the self-test
    /// slate swapped this for a counter and put back whatever it had seen,
    /// and the real sink arrives from a config fetch that can land in the
    /// middle of that drill: the restore put back nil, every event after
    /// the slate went to a backlog nothing would ever drain, and PostHog
    /// received exactly the launch events replayed at attach and nothing
    /// else, on every deploy, while the local record looked complete.
    nonisolated(unsafe) public private(set) static var sink: (@Sendable (TrackEvent) -> Void)?
    nonisolated(unsafe) public static var trace: (@Sendable (String) -> Void)?

    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "base.tranquility.track", qos: .utility)
    nonisolated(unsafe) private static var storeURL: URL?
    nonisolated(unsafe) private static var salt: String = ""
    nonisolated(unsafe) private static var _suppressed = false
    nonisolated(unsafe) private static var _recorded = 0
    nonisolated(unsafe) private static var _refused = 0
    nonisolated(unsafe) private static var _suppressedDrops = 0
    nonisolated(unsafe) private static var common: [String: TrackValue] = [:]
    /// Events recorded before a sink exists (app launch happens a run-loop
    /// turn before the SDK starts). Replayed on `attach`, capped so a sink
    /// that never comes cannot grow this without bound.
    nonisolated(unsafe) private static var pending: [TrackEvent] = []
    private static let pendingLimit = 200
    private static let limit = 8 * 1024 * 1024

    /// Hand the funnel its sink and replay what was recorded before it
    /// existed, in order, on the funnel's own queue.
    public static func attach(sink newSink: @escaping @Sendable (TrackEvent) -> Void) {
        lock.lock()
        let backlog = pending
        pending = []
        sink = newSink
        lock.unlock()
        queue.async { for event in backlog { newSink(event) } }
    }

    /// No sink: events go to the backlog again. The service was turned off,
    /// or a test is done with its counter.
    public static func detach() {
        lock.lock(); sink = nil; lock.unlock()
    }

    public static var hasSink: Bool { lock.lock(); defer { lock.unlock() }; return sink != nil }

    /// Point the funnel at a directory and give it the install id as salt.
    public static func configure(directory: URL, installId: String) {
        lock.lock(); defer { lock.unlock() }
        storeURL = directory.appendingPathComponent("events.jsonl")
        salt = installId
    }

    public static var eventsURL: URL? { lock.lock(); defer { lock.unlock() }; return storeURL }

    /// Properties every event carries (build, arch, macOS). Set once.
    public static func setCommon(_ props: [String: TrackValue]) {
        lock.lock(); common = props; lock.unlock()
    }

    /// While true, nothing is written or forwarded; the self-test slate
    /// turns this on. Counted, so a drill can prove the wiring.
    public static var suppressed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _suppressed }
        set { lock.lock(); _suppressed = newValue; lock.unlock() }
    }
    public static var recordedCount: Int { lock.lock(); defer { lock.unlock() }; return _recorded }
    public static var refusedCount: Int { lock.lock(); defer { lock.unlock() }; return _refused }
    /// How many admissible events were dropped because `suppressed` was on.
    /// A drill proves suppression by this count moving, never by swapping
    /// the sink.
    public static var suppressedCount: Int { lock.lock(); defer { lock.unlock() }; return _suppressedDrops }

    /// The app's own prose ("grid from goHomeFromCard(via:):1428", "arm
    /// reverted: tap or chord", "TranquilityApp/StatusHUD.swift:1331") as a
    /// token: lowercase, every character outside the vocabulary becomes an
    /// underscore, runs collapse, capped. Reasons and sites are the app's
    /// words, never a person's, so this is shaping, not scrubbing.
    public static func token(from prose: String) -> TrackValue {
        var out = ""
        var lastUnderscore = false
        for scalar in prose.lowercased().unicodeScalars {
            if TrackValue.tokenAllowed.contains(scalar), scalar != "-" || true {
                let ch = Character(scalar)
                if ch == "_" || ch == "-" {
                    if !lastUnderscore { out.append("_"); lastUnderscore = true }
                } else { out.append(ch); lastUnderscore = false }
            } else if !lastUnderscore { out.append("_"); lastUnderscore = true }
        }
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        if out.isEmpty { out = "none" }
        return .token(String(out.prefix(48)))
    }

    /// App copy as a token: the fixed phrase before the first colon or full
    /// stop, where the app's sentences put their own words, and never what
    /// comes after, where they put the user's ("Typed into Terminal.",
    /// "Install id copied: ad8e...", "could not save. <error>").
    public static func phrase(_ text: String) -> TrackValue {
        let head = text.split(whereSeparator: { $0 == ":" || $0 == "." }).first.map(String.init) ?? text
        return token(from: String(head.prefix(32)))
    }

    /// The agent's or the app's own words, scrubbed at the door. Never the
    /// person's: see `TrackValue.prose`.
    public static func prose(_ text: String) -> TrackValue { .prose(text) }

    /// A thing on the user's machine, as something that can be counted and
    /// followed but not read. Sixteen hex characters of a salted SHA-256.
    public static func hash(_ id: String) -> TrackValue {
        lock.lock(); let s = salt; lock.unlock()
        let digest = SHA256.hash(data: Data((s + ":" + id).utf8))
        return .hash(digest.prefix(8).map { String(format: "%02x", $0) }.joined())
    }

    /// Record one event. Cheap on the caller's thread.
    public static func record(_ name: String, _ properties: [String: TrackValue] = [:]) {
        let now = Date()
        let capture = captureID.map { hash($0) }
        let attempt = attemptID.map { hash($0) }
        lock.lock()
        let suppressed = _suppressed
        let url = storeURL
        let base = common
        _recorded += 1
        lock.unlock()
        // The door: a name and every value must be admissible, or the event
        // is dropped whole and said so. Dropping half an event would leave a
        // record that looks complete.
        let properties = properties.mapValues { $0.scrubbed }
        let nameOK = TrackValue.token(name).isAdmissible
        let bad = properties.filter { !$0.value.isAdmissible }.map(\.key)
        guard nameOK, bad.isEmpty else {
            lock.lock(); _refused += 1; lock.unlock()
            trace?("refused \(name): inadmissible \(nameOK ? bad.joined(separator: ",") : "name")")
            return
        }
        guard !suppressed else {
            lock.lock(); _suppressedDrops += 1; lock.unlock()
            return
        }
        lock.lock()
        sequence += 1
        let number = sequence
        lock.unlock()
        var enriched = base.merging(properties) { _, new in new }
        enriched["event_sequence"] = .int(number)
        enriched["event_process_id"] = .token(processID)
        enriched["source_time_ms"] = .double(now.timeIntervalSince1970 * 1000)
        if let capture { enriched["capture_id"] = capture }
        if let attempt { enriched["attempt_id"] = attempt }
        let event = TrackEvent(name: name, at: now, properties: enriched)
        queue.async {
            if let url { append(event, to: url) }
            if let sink {
                sink(event)
            } else {
                lock.lock()
                if pending.count < pendingLimit { pending.append(event) }
                lock.unlock()
            }
        }
    }

    private static func append(_ event: TrackEvent, to url: URL) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var dict: [String: Any] = ["event": event.name, "at": iso.string(from: event.at)]
        for (k, v) in event.properties { dict[k] = v.json }
        guard var line = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let size = lseek(fd, 0, SEEK_CUR)
        close(fd)
        if size > limit {
            let rolled = url.deletingPathExtension().appendingPathExtension("jsonl.1")
            try? FileManager.default.removeItem(at: rolled)
            try? FileManager.default.moveItem(at: url, to: rolled)
        }
    }

    /// Block until queued events are written. Tests and termination.
    public static func flush() { queue.sync {} }

    /// Words in a transcript, as a count. The text itself never leaves.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// The reply event, in one place so every outcome carries the same
    /// shape: which stage decided (capture, before the undo window; confirm,
    /// after it), what it decided, and how much was said, as counts.
    public static func replyOutcome(_ outcome: String, stage: String, agent: String? = nil,
                                    text: String? = nil, extra: [String: TrackValue] = [:]) {
        var props: [String: TrackValue] = ["outcome": .token(outcome), "stage": .token(stage)]
        if let agent { props["agent_id"] = hash(agent) }
        if let text { props["chars"] = .int(text.count); props["words"] = .int(wordCount(text)) }
        for (k, v) in extra { props[k] = v }
        record("reply_outcome", props)
    }

    /// Tests only.
    public static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        storeURL = nil; salt = ""; _suppressed = false; _recorded = 0; _refused = 0; _suppressedDrops = 0; common = [:]
        pending = []
        sink = nil
    }
}

// MARK: - Watchers the spines use

/// The lamp spine: remembers what each agent's row looked like on the last
/// tick and emits one event per change. Pure; the app feeds it rows.
public struct LampWatch: Sendable {
    public struct Seen: Equatable, Sendable {
        public var lamp: String
        public var read: String
        public var reason: String
        public var since: Date
        public init(lamp: String, read: String, reason: String, since: Date) {
            self.lamp = lamp; self.read = read; self.reason = reason; self.since = since
        }
    }
    private var seen: [String: Seen] = [:]
    private var seeded = false
    public init() {}

    /// Feed the current rows; returns the events to record. The first feed
    /// seeds silently: forty rows at launch are a census, not forty changes,
    /// and `grid_census` already says how many there are.
    public mutating func observe(_ rows: [(id: String, harness: String, lamp: String, read: String, reason: String)],
                                 now: Date = Date()) -> [TrackEvent] {
        if !seeded {
            seeded = true
            for row in rows { seen[row.id] = Seen(lamp: row.lamp, read: row.read, reason: row.reason, since: now) }
            return []
        }
        var out: [TrackEvent] = []
        var current: [String: Seen] = [:]
        for row in rows {
            let next = Seen(lamp: row.lamp, read: row.read, reason: row.reason, since: now)
            if let prior = seen[row.id] {
                if prior.lamp != row.lamp || prior.read != row.read {
                    var props: [String: TrackValue] = [
                        "agent_id": Track.hash(row.id), "harness": .token(row.harness),
                        "from": .token(prior.lamp), "to": .token(row.lamp), "read": .token(row.read),
                        "reason": .token(Self.reasonToken(row.reason)),
                        "seconds_in_previous": .int(Int(now.timeIntervalSince(prior.since))),
                    ]
                    // The harness's own sentence, when the row has one. This is
                    // where "429 rate limit" and "stream disconnected" actually
                    // live, and the classified word above cannot carry them.
                    if let detail = Self.detail(row.reason) { props["detail"] = detail }
                    out.append(TrackEvent(name: "agent_lamp_changed", at: now, properties: props))
                    current[row.id] = next
                } else {
                    current[row.id] = prior
                }
            } else {
                out.append(TrackEvent(name: "agent_lamp_changed", at: now, properties: [
                    "agent_id": Track.hash(row.id), "harness": .token(row.harness),
                    "from": "none", "to": .token(row.lamp), "read": .token(row.read),
                    "reason": .token(Self.reasonToken(row.reason)), "seconds_in_previous": 0,
                ]))
                current[row.id] = next
            }
        }
        for (id, prior) in seen where current[id] == nil {
            out.append(TrackEvent(name: "agent_lamp_changed", at: now, properties: [
                "agent_id": Track.hash(id), "from": .token(prior.lamp), "to": "gone", "read": "none",
                "reason": "left_the_grid", "seconds_in_previous": .int(Int(now.timeIntervalSince(prior.since))),
            ]))
        }
        seen = current
        return out
    }

    /// A row's reason column is prose, and for a blocked or stalled row it
    /// is the AGENT'S prose: the first sentence of whatever error the
    /// harness printed ("stream disconnected before completion: error
    /// sending request for url ..."). Until 7 Sep this took its first four
    /// words into the record. Now it classifies into a vocabulary and never
    /// emits a word from the string itself.
    /// The row's own words, when they are the agent's rather than a bare id
    /// or one of the app's short states.
    static func detail(_ reason: String) -> TrackValue? {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return nil }
        return .prose(trimmed)
    }

    static func reasonToken(_ reason: String) -> String {
        let r = reason.lowercased()
        if r.isEmpty { return "none" }
        // An eight-hex short id stands in for a row with no reason.
        if r.count == 8, r.unicodeScalars.allSatisfy({ ("0"..."9").contains(Character(String($0))) || ("a"..."f").contains(Character(String($0))) }) {
            return "none"
        }
        let app: [(String, String)] = [
            ("needs you", "needs_you"), ("waiting", "waiting"), ("answering", "answering"),
            ("working", "working"), ("thinking", "working"), ("running", "running"),
            ("asked", "asked"), ("blocked", "blocked"), ("stalled", "stalled"),
            ("reviving", "reviving"), ("starting", "starting"), ("launch", "launching"),
            ("ended", "ended"), ("exited", "ended"), ("done", "done"), ("idle", "idle"),
        ]
        for (needle, token) in app where r.contains(needle) { return token }
        if r.contains("rate limit") || r.contains("429") { return "rate_limit" }
        if r.contains("quota") || r.contains("usage limit") || r.contains("credit") || r.contains("billing") { return "quota" }
        if r.contains("disconnect") || r.contains("network") || r.contains("connection")
            || r.contains("request") || r.contains("timed out") || r.contains("timeout") { return "network" }
        if r.contains("permission") || r.contains("denied") || r.contains("trust") { return "permission" }
        if r.contains("auth") || r.contains("login") || r.contains("sign in") || r.contains("token") { return "auth" }
        if r.contains("error") || r.contains("fail") { return "error" }
        return "other"
    }
}
