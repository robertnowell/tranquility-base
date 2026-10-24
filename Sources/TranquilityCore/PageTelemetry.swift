import CryptoKit
import Foundation

/// How many pages agents publish, and which rules each session held.
///
/// Robert, 24 Oct 2026: "this should be in our telemetry. we should know how
/// many documents are created, what rules each mac is using, we need to know
/// how our users are using the app." Until then the per-session rules record
/// (rules/seen/<session>) and every page lived only on the Mac that made
/// them, so whether another Mac followed the rules was guesswork.
///
/// Two events, both through `Track`, so the door's rules hold: tokens,
/// numbers, bools and hashes, never text.
///
/// - `page_published`: one per write of a live page, from the line
///   artifact-hook.sh appends to rules/pages.jsonl. The first write of a
///   path is version 1; a later write of the same path is a republish,
///   `republished: true` with its version, so a count of version 1 is a
///   count of pages.
/// - `turn_completed`: one per finished turn the spool files, with the
///   agent (hashed), its harness and the rules version its session holds.
/// - `session_seen`: once when a session's first turn is filed, and again
///   each time the rules version it holds changes (visual-output-hook.sh
///   writes it at session start; tbase-hook.sh refreshes it on a later
///   prompt). `current` says whether it equals what this install ships.
///
/// How this relates to `rules_state`: that event's `fingerprint` names the
/// whole staged rules store, once per install per reconcile. The session
/// version here is a hash of only the two files that make the text a session
/// is told (visual-output-hook.sh and shape-context.txt). One install has one
/// fingerprint at a time and many sessions, each holding whichever session
/// version it was last given.
public enum PageTelemetry {

    public typealias Emit = (_ name: String, _ properties: [String: TrackValue]) -> Void

    struct Line: Decodable {
        var at_ms: Int64
        var session: String
        var path: String
        var harness: String?
        var type: String?
        var brand: String?
        var rules: String?
        var words: Int?
        var claims: Int?
        var semicolons: Int?
        var long_sentences: Int?
        var headline_has_verb: Bool?
        var ste_flags: Int?
    }

    struct State: Codable {
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            offset = try c.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
            versions = try c.decodeIfPresent([String: Int].self, forKey: .versions) ?? [:]
            sessions = try c.decodeIfPresent([String: String].self, forKey: .sessions) ?? [:]
            harnesses = try c.decodeIfPresent([String: String].self, forKey: .harnesses) ?? [:]
        }
        var offset: UInt64 = 0
        /// sha256(path) -> how many writes were reported.
        var versions: [String: Int] = [:]
        /// session -> the rules version last reported for it.
        var sessions: [String: String] = [:]
        /// session -> its harness, learned from its first filed turn.
        var harnesses: [String: String] = [:]
    }

    static func stateURL(_ root: URL) -> URL { root.appendingPathComponent("pages-telemetry.json") }
    static func logURL(_ root: URL) -> URL { root.appendingPathComponent("pages.jsonl") }

    static func load(_ root: URL) -> State {
        guard let data = try? Data(contentsOf: stateURL(root)),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return s
    }

    static func save(_ s: State, _ root: URL) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: stateURL(root), options: .atomic)
    }

    /// The version a session is told now: the same hash visual-output-hook.sh
    /// prints, of its own text followed by shape-context.txt.
    public static func currentSessionVersion(root: URL = RulesStore.root) -> String? {
        let cur = RulesStore.current(in: root)
        guard let hook = try? Data(contentsOf: cur.appendingPathComponent("hooks/visual-output-hook.sh")) else { return nil }
        let ctx = (try? Data(contentsOf: cur.appendingPathComponent("skills/share-as-page/references/shape-context.txt"))) ?? Data()
        let digest = SHA256.hash(data: hook + ctx)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    static func token(_ s: String?, fallback: String = "unknown") -> TrackValue {
        let v = TrackValue.token(s ?? "")
        return v.isAdmissible ? v : .token(fallback)
    }

    static func version(_ s: String?) -> String {
        guard let s, s.range(of: "^[0-9a-f]{6,64}$", options: .regularExpression) != nil else { return "none" }
        return s
    }

    /// Read what is new since the last drain and emit it. Idempotent: a
    /// line or a session version is reported once, whatever calls this.
    private static let lock = NSLock()

    public static func drain(root: URL = RulesStore.root, emit: Emit) {
        lock.lock(); defer { lock.unlock() }
        var state = load(root)
        drainPages(root: root, state: &state, emit: emit)
        drainSessions(root: root, state: &state, emit: emit)
        save(state, root)
    }

    /// Finished turns the spool just filed (`SpoolDrainer.DrainResult.completed`).
    public static func turnsCompleted(_ turns: [(session: String, harness: String)],
                                      root: URL = RulesStore.root, emit: Emit) {
        guard !turns.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var state = load(root)
        let current = currentSessionVersion(root: root)
        for turn in turns where ArtifactStore.isPlausibleSession(turn.session) {
            let rules = seenVersion(turn.session, root: root)
            let harness = token(turn.harness)
            emit("turn_completed", ["agent_id": Track.hash(turn.session), "harness": harness,
                                    "rules_version": .token(rules)])
            if state.harnesses[turn.session] == nil {
                state.harnesses[turn.session] = harness.tokenString
                state.sessions[turn.session] = rules
                emit("session_seen", sessionProps(turn.session, harness: harness.tokenString, rules: rules,
                                                  current: current, first: true))
            }
        }
        save(state, root)
    }

    static func seenVersion(_ session: String, root: URL) -> String {
        let url = RulesStore.seenDirectory(in: root).appendingPathComponent(session)
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return version(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func sessionProps(_ session: String, harness: String, rules: String,
                             current: String?, first: Bool) -> [String: TrackValue] {
        ["agent_id": Track.hash(session), "harness": token(harness), "rules_version": .token(rules),
         "current": .bool(current != nil && rules == current), "first": .bool(first)]
    }

    static func drainPages(root: URL, state: inout State, emit: Emit) {
        guard let handle = try? FileHandle(forReadingFrom: logURL(root)) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset { state.offset = 0 }          // replaced or truncated: start over
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Only whole lines: a line the hook is still writing waits for the next drain.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        state.offset += UInt64(complete.count)
        for raw in complete.split(separator: UInt8(ascii: "\n")) {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw)),
                  ArtifactStore.isPlausibleSession(line.session) else { continue }
            let key = SHA256.hash(data: Data(line.path.utf8)).map { String(format: "%02x", $0) }.joined()
            let n = (state.versions[key] ?? 0) + 1
            state.versions[key] = n
            var props: [String: TrackValue] = [
                "agent_id": Track.hash(line.session),
                "rules_version": .token(version(line.rules)),
                "harness": token(line.harness),
                "page_type": token(line.type.flatMap { $0.isEmpty ? nil : $0 }, fallback: "none"),
                "words": .int(line.words ?? 0),
                "claims": .int(line.claims ?? 0),
                "semicolons": .int(line.semicolons ?? 0),
                "long_sentences": .int(line.long_sentences ?? 0),
                "headline_has_verb": .bool(line.headline_has_verb ?? false),
                "ste_flags": .int(line.ste_flags ?? 0),
                "version": .int(n),
                "republished": .bool(n > 1),
                "written_at": .int(Int(line.at_ms / 1000)),
            ]
            if let brand = line.brand, !brand.isEmpty { props["brand"] = Track.hash(brand.lowercased()) }
            emit("page_published", props)
        }
    }

    /// A session already seen whose rules record changed: say so. A session
    /// with a record but no filed turn yet waits for its first turn, which
    /// is when its harness is known.
    static func drainSessions(root: URL, state: inout State, emit: Emit) {
        let current = currentSessionVersion(root: root)
        let dir = RulesStore.seenDirectory(in: root)
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        for (session, harness) in state.harnesses.sorted(by: { $0.key < $1.key }) {
            guard names.contains(session) else { continue }
            let v = seenVersion(session, root: root)
            guard state.sessions[session] != v else { continue }
            state.sessions[session] = v
            emit("session_seen", sessionProps(session, harness: harness, rules: v, current: current, first: false))
        }
        // Kept even when RulesStore.pruneSeen removes the record: a session
        // forgotten here would be "first" again at its next turn. A few
        // bytes per session; bounded at 20,000 by dropping the record of
        // sessions whose seen file is gone.
        if state.harnesses.count > 20_000 {
            state.harnesses = state.harnesses.filter { names.contains($0.key) }
            state.sessions = state.sessions.filter { names.contains($0.key) }
        }
    }
}
