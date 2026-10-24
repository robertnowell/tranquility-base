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
/// - `session_rules`: one per session each time the rules version it was
///   given changes (visual-output-hook.sh writes it at session start;
///   tbase-hook.sh refreshes it on a later prompt). `current` says whether
///   it equals the version this install ships now.
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
        var offset: UInt64 = 0
        /// sha256(path) -> how many writes were reported.
        var versions: [String: Int] = [:]
        /// session -> the rules version last reported for it.
        var sessions: [String: String] = [:]
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

    static func drainSessions(root: URL, state: inout State, emit: Emit) {
        let dir = RulesStore.seenDirectory(in: root)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let current = currentSessionVersion(root: root)
        for name in names.sorted() where ArtifactStore.isPlausibleSession(name) {
            let raw = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
            let v = version(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard state.sessions[name] != v else { continue }
            let first = state.sessions[name] == nil
            state.sessions[name] = v
            emit("session_rules", [
                "agent_id": Track.hash(name),
                "rules_version": .token(v),
                "current": .bool(current != nil && v == current),
                "first": .bool(first),
            ])
        }
        // Forget sessions whose record RulesStore.pruneSeen removed.
        let live = Set(names)
        state.sessions = state.sessions.filter { live.contains($0.key) }
    }
}
