import CryptoKit
import Foundation

/// The mirror: every page and every turn, into the hub, from the panel itself.
///
/// Until 12 Sep 2026 this was a Node script in a repo checkout, fired by three
/// hook entries in one person's Claude Code settings, with a token in a file
/// and a Google account for the images. None of it could reach a second Mac.
/// The panel already holds everything the script read (the brief store, the
/// artifact records, the archive on disk, the app address in hq.json), so the
/// mirror lives here, runs while the panel runs, and needs no hook of its own.
///
/// Three rules keep it from surprising anyone:
///
///  1. One record, one key. A page is keyed by the hash of its bytes, a turn by
///     its session and event row, on the server. A catch-up can never insert
///     twice, so the mirror is free to re-check everything whenever it likes.
///  2. Nothing is lost by being closed. Briefs sit in the store and pages sit on
///     disk; the next run picks up where the cursor and the file marks say.
///  3. Silence is visible. Every run ends with a heartbeat that says what it
///     sent or why it failed; the hub prints it red when it is not "ok".
///
/// The routes and the shapes are exactly the script's (hq-app scripts/upload.mjs
/// was the spec): /api/ingest/known, /api/ingest, /api/ingest/turns,
/// /api/ingest/names, /api/heartbeat, and /api/ingest/assets for images.
public final class HubMirror: @unchecked Sendable {

    // MARK: - Transport

    /// One seam for the network, so a test never opens a socket.
    public protocol Transport: Sendable {
        func post(_ path: String, json: [String: Any]) async throws -> (status: Int, body: Data)
    }

    public struct URLSessionTransport: Transport {
        public let base: URL
        public let token: String
        public var session: URLSession = .shared
        public init(base: URL, token: String, session: URLSession = .shared) {
            self.base = base; self.token = token; self.session = session
        }
        public func post(_ path: String, json: [String: Any]) async throws -> (status: Int, body: Data) {
            var req = URLRequest(url: base.appendingPathComponent(path))
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, data)
        }
    }

    // MARK: - State

    /// What has been sent, so a run is a diff and never a repeat.
    struct State: Codable {
        struct Mark: Codable { var size: Int64; var mtimeMs: Int64; var hash: String }
        var files: [String: Mark] = [:]
        var sent: Set<String> = []
        var turnCursor: Int64 = 0
        var names: [String: String] = [:]
        /// sha256 of an image -> its public address, so a screenshot pasted
        /// into four pages uploads once.
        var assets: [String: String] = [:]
        var lastHeartbeatAt: Date?
        var lastHeartbeatNote: String?
    }

    public struct Report: Sendable, Equatable {
        public var documents = 0, turns = 0, renamed = 0, images = 0
        public var failed = 0
        public var note: String = ""
    }

    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?
    /// The one the app runs. Nil until the machine is connected.
    public nonisolated(unsafe) static var shared: HubMirror?

    public let transport: Transport
    public let agentsRoot: String
    public let stateURL: URL
    public let device: String
    public let store: QueueStore?
    /// Where the artifact hook's records live (first-write times for pages).
    public let artifactRoot: String?
    /// Live sessions, for the harness's own name. Injectable; the default asks
    /// the CLI, which caches for six seconds.
    public var liveSessions: @Sendable () -> [String: LiveSession] = {
        Dictionary((ClaudeAgentsCLI().sessions() ?? []).map { ($0.sessionId, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    private let lock = NSLock()
    /// Every touch of `state` goes through here; `withLock` is synchronous,
    /// so it is legal from the async passes where a bare lock() is not.
    private func sync<T>(_ body: () -> T) -> T { lock.withLock(body) }
    private var state: State
    private var running = false
    private var pending = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "hub-mirror", qos: .utility)

    public init(transport: Transport, agentsRoot: String, stateURL: URL, device: String,
                store: QueueStore?, artifactRoot: String?) {
        self.transport = transport
        self.agentsRoot = agentsRoot
        self.stateURL = stateURL
        self.device = device
        self.store = store
        self.artifactRoot = artifactRoot
        self.state = Self.load(stateURL)
    }

    // MARK: - The machine's own

    /// The mirror for this Mac, or nil while it is not connected: no app
    /// address in hq.json, or no token. The token moves from the script's
    /// file into the panel's secrets the first time it is seen; the file is
    /// left where it was until the connect flow replaces it.
    public static func fromMachine(store: QueueStore?) -> HubMirror? {
        guard let base = HubApp.baseURL else { trace?("no app.base_url in hq.json; not mirroring"); return nil }
        var token = Secrets.read(.hubToken)
        if token == nil {
            let legacy = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/hq/token")
            if let t = try? String(contentsOf: legacy, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                try? Secrets.write(.hubToken, value: t)
                token = t
                trace?("token adopted from the script's file")
            }
        }
        guard let token else { trace?("no hub token; not mirroring"); return nil }
        let support = QueueStore.supportDirectory
        return HubMirror(
            transport: URLSessionTransport(base: base, token: token),
            agentsRoot: NSString(string: "~/Documents/agents").expandingTildeInPath,
            stateURL: support.appendingPathComponent("hub-mirror-state.json"),
            device: deviceName(),
            store: store,
            artifactRoot: support.path)
    }

    /// The same spelling the script used, so the hub keeps one row per Mac.
    public static func deviceName() -> String {
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name = String(name.dropLast(".local".count)) }
        return name.isEmpty ? "mac" : name
    }

    // MARK: - Running

    /// Start the sweep: a full pass now, then every `every` seconds. A page
    /// or a turn that lands between sweeps is picked up by `kick()`.
    public func start(every: TimeInterval = 300, docsEvery: TimeInterval = 20) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: docsEvery)
        var ticks = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            ticks += 1
            let full = ticks == 1 || Double(ticks) * docsEvery >= every
            if full { ticks = 1 }
            Task { _ = await self.run(names: full) }
        }
        t.resume()
        timer = t
    }

    /// Run soon. Coalesces: a burst of briefs is one pass, and a pass that is
    /// already running is followed by exactly one more.
    public func kick() {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            Task { _ = await self.run() }
        }
    }

    @discardableResult
    public func run(docs: Bool = true, turns: Bool = true, names: Bool = false) async -> Report {
        let busy: Bool = sync {
            if running { pending = true; return true }
            running = true; return false
        }
        if busy { return Report(note: "already running") }
        defer {
            let again: Bool = sync { running = false; let a = pending; pending = false; return a }
            if again { kick() }
        }
        var report = Report()
        if docs { await mirrorDocuments(&report) }
        if turns, store != nil { await mirrorTurns(&report) }
        if names, store != nil { await mirrorNames(&report) }
        report.note = report.failed == 0
            ? "ok: \(report.documents) documents, \(report.turns) turns"
            : "failed: \(report.failed) request(s); last: \(report.note)"
        await heartbeat(report.note)
        save()
        Self.trace?(report.note + (report.images > 0 ? " · \(report.images) image(s)" : ""))
        return report
    }

    // MARK: - Documents

    struct Candidate { let path: String; let session: String; let hash: String; let mtime: Date }

    static let sessionDir = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .caseInsensitive)

    func mirrorDocuments(_ report: inout Report) async {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: agentsRoot) else { return }
        var candidates: [Candidate] = []
        var marks: [String: State.Mark] = [:]
        for dir in dirs.sorted() {
            guard Self.sessionDir.firstMatch(in: dir, range: NSRange(dir.startIndex..., in: dir)) != nil else { continue }
            let base = agentsRoot + "/" + dir
            for path in Self.walk(base) where path != base + "/index.html" {
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? Int64,
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                let mtimeMs = Int64(mtime.timeIntervalSince1970 * 1000)
                var hash: String? = nil
                if let old = sync({ state.files[path] }), old.size == size, old.mtimeMs == mtimeMs {
                    hash = old.hash
                } else {
                    guard var html = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                    if html.contains("research-hq-generated: index") { continue }
                    if Self.hasImagesToMove(html) {
                        let moved = await moveImages(of: path, html: html, report: &report)
                        if moved { html = (try? String(contentsOfFile: path, encoding: .utf8)) ?? html }
                    }
                    hash = Self.sha256(html)
                }
                guard let hash else { continue }
                // The mark is the file as it is now (an image move rewrites it).
                let now = (try? fm.attributesOfItem(atPath: path)) ?? attrs
                marks[path] = State.Mark(size: (now[.size] as? Int64) ?? size,
                                         mtimeMs: Int64(((now[.modificationDate] as? Date) ?? mtime).timeIntervalSince1970 * 1000),
                                         hash: hash)
                candidates.append(Candidate(path: path, session: dir, hash: hash, mtime: mtime))
            }
        }
        sync { state.files = marks }

        // Ask once which of the unsent hashes the hub already holds.
        let sentBefore = sync { state.sent }
        let unsent = candidates.filter { !sentBefore.contains($0.hash) }
        var known = Set<String>()
        for chunk in stride(from: 0, to: unsent.count, by: 5000).map({ Array(unsent[$0..<min($0 + 5000, unsent.count)]) }) {
            do {
                let (status, body) = try await transport.post("api/ingest/known", json: ["hashes": chunk.map(\.hash)])
                guard status == 200,
                      let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let list = obj["known"] as? [String] else {
                    report.failed += 1; report.note = "known: HTTP \(status)"; return
                }
                known.formUnion(list)
            } catch { report.failed += 1; report.note = "known: \(error.localizedDescription)"; return }
        }
        sync { state.sent.formUnion(known) }

        let firstWrites = firstWriteTimes(for: Set(unsent.map(\.session)))
        for c in unsent.filter({ !known.contains($0.hash) }).sorted(by: { $0.mtime < $1.mtime }) {
            guard let html = try? String(contentsOfFile: c.path, encoding: .utf8) else { continue }
            let slug = Self.slug(path: c.path, base: agentsRoot + "/" + c.session)
            var json: [String: Any] = [
                "session_id": c.session, "slug": slug, "title": Self.title(of: html, slug: slug),
                "html": html, "device": device,
                "produced_at": Self.iso(firstWrites[c.path] ?? Self.birth(of: c.path) ?? c.mtime),
            ]
            if let pub = Self.meta(html, "url"), pub.hasPrefix("http") { json["published_url"] = pub }
            do {
                let (status, body) = try await transport.post("api/ingest", json: json)
                guard (200..<300).contains(status) else {
                    report.failed += 1
                    report.note = "ingest \(slug): HTTP \(status) \(String(decoding: body.prefix(120), as: UTF8.self))"
                    continue
                }
                sync { state.sent.insert(c.hash) }
                report.documents += 1
            } catch { report.failed += 1; report.note = "ingest \(slug): \(error.localizedDescription)" }
        }
    }

    /// Every .html under a session directory, to a sane depth, skipping the
    /// panel's own hub and anything hidden or archived.
    static func walk(_ base: String, depth: Int = 0) -> [String] {
        guard depth <= 6, let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        var out: [String] = []
        for n in names.sorted() where !n.hasPrefix(".") && !n.hasPrefix("_") {
            let p = base + "/" + n
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            if isDir.boolValue { out += walk(p, depth: depth + 1) }
            else if n.hasSuffix(".html") { out.append(p) }
        }
        return out
    }

    /// The page's name in the hub: the path under the agent directory, `.html`
    /// dropped, slashes folded. The same rule as `HubApp.locate`, pinned there.
    static func slug(path: String, base: String) -> String {
        var rel = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : (path as NSString).lastPathComponent
        if rel.hasSuffix(".html") { rel = String(rel.dropLast(5)) }
        return rel.replacingOccurrences(of: "/", with: "-")
    }

    static func title(of html: String, slug: String) -> String {
        let head = String(html.prefix(64_000))
        for pattern in ["<title[^>]*>([\\s\\S]*?)</title>", "<h1[^>]*>([\\s\\S]*?)</h1>"] {
            if let r = head.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let inner = String(head[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let t = inner.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return String(t.prefix(200)) }
            }
        }
        return slug
    }

    /// `<meta name="intranet:NAME" content="...">`, either attribute order.
    static func meta(_ html: String, _ name: String) -> String? {
        let head = String(html.prefix(16_000))
        let a = "<meta\\s+name=\"intranet:\(name)\"\\s+content=\"([^\"]*)\""
        let b = "<meta\\s+content=\"([^\"]*)\"\\s+name=\"intranet:\(name)\""
        for p in [a, b] {
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                  let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
                  let r = Range(m.range(at: 1), in: head) else { continue }
            let v = String(head[r]).trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    func firstWriteTimes(for sessions: Set<String>) -> [String: Date] {
        guard let root = artifactRoot else { return [:] }
        var out: [String: Date] = [:]
        for s in sessions {
            for page in ArtifactStore.history(for: s, root: root) {
                if out[page.path] == nil || page.at < out[page.path]! { out[page.path] = page.at }
            }
        }
        return out
    }

    static func birth(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func sha256(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Images

    /// Inline `data:` images, and files beside the page, both leave the page
    /// for the media bucket and the page points at them by absolute address.
    /// The extractor's rule, with the app doing the upload instead of a
    /// Google account on the laptop. All-or-nothing per page: a page with a
    /// hole is worse than a heavy one.
    static let dataURI = try! NSRegularExpression(
        pattern: "data:(image/(?:jpeg|jpg|png|gif|webp|avif));base64,([A-Za-z0-9+/=\\s]{40,})", options: [])
    static let relativeRef = try! NSRegularExpression(
        pattern: "<(?:img|source|video)\\b[^>]*?\\s(?:src|poster)=\"((?!https?:|data:|/|#|//)[^\"?#]+?\\.(?:png|jpe?g|gif|webp|avif))\"",
        options: .caseInsensitive)
    static let maxImage = 3_500_000
    static let mimeByExt = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                            "gif": "image/gif", "webp": "image/webp", "avif": "image/avif"]

    static func hasImagesToMove(_ html: String) -> Bool {
        let range = NSRange(html.startIndex..., in: html)
        return dataURI.firstMatch(in: html, range: range) != nil || relativeRef.firstMatch(in: html, range: range) != nil
    }

    /// Returns true when the page on disk was rewritten.
    func moveImages(of path: String, html: String, report: inout Report) async -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        let range = NSRange(html.startIndex..., in: html)
        struct Move { let find: String; let bytes: Data; let mime: String }
        var moves: [Move] = []
        for m in Self.dataURI.matches(in: html, range: range) {
            guard let whole = Range(m.range, in: html), let mr = Range(m.range(at: 1), in: html),
                  let br = Range(m.range(at: 2), in: html) else { continue }
            let b64 = String(html[br]).filter { !$0.isWhitespace }
            guard let bytes = Data(base64Encoded: b64) else { continue }
            moves.append(Move(find: String(html[whole]), bytes: bytes, mime: String(html[mr])))
        }
        var seenRefs = Set<String>()
        for m in Self.relativeRef.matches(in: html, range: range) {
            guard let rr = Range(m.range(at: 1), in: html) else { continue }
            let rel = String(html[rr])
            guard !seenRefs.contains(rel) else { continue }
            seenRefs.insert(rel)
            let target = URL(fileURLWithPath: dir).appendingPathComponent(rel).standardizedFileURL.path
            guard target.hasPrefix(dir + "/"), let bytes = FileManager.default.contents(atPath: target) else { continue }
            let ext = (target as NSString).pathExtension.lowercased()
            moves.append(Move(find: "\"" + rel + "\"", bytes: bytes, mime: Self.mimeByExt[ext] ?? "application/octet-stream"))
        }
        guard !moves.isEmpty else { return false }
        var rewritten = html
        for mv in moves {
            guard mv.bytes.count <= Self.maxImage else { Self.trace?("image too large to move in \(slugName(path))"); return false }
            let sha = Self.sha256(mv.bytes)
            var url = sync { state.assets[sha] }
            if url == nil {
                do {
                    let (status, body) = try await transport.post("api/ingest/assets", json: [
                        "content_type": mv.mime, "data_base64": mv.bytes.base64EncodedString(), "sha256": sha])
                    guard status == 200,
                          let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          let u = obj["url"] as? String else {
                        report.failed += 1; report.note = "asset: HTTP \(status)"; return false
                    }
                    url = u
                    sync { state.assets[sha] = u }
                    report.images += 1
                } catch { report.failed += 1; report.note = "asset: \(error.localizedDescription)"; return false }
            }
            let replacement = mv.find.hasPrefix("\"") ? "\"" + url! + "\"" : url!
            rewritten = rewritten.replacingOccurrences(of: mv.find, with: replacement)
        }
        guard rewritten != html else { return false }
        HubReconcile.write(rewritten, to: URL(fileURLWithPath: path))
        Self.trace?("moved \(moves.count) image(s) out of \(slugName(path))")
        return true
    }

    private func slugName(_ path: String) -> String { (path as NSString).lastPathComponent }

    // MARK: - Turns

    func mirrorTurns(_ report: inout Report) async {
        guard let store else { return }
        let sessions = knownSessions()
        let live = liveSessions()
        var cursor = sync { state.turnCursor }
        while true {
            guard let batch = try? store.briefs(after: cursor, limit: 100), !batch.isEmpty else { break }
            let turns: [[String: Any]] = batch.map { b in
                Self.turnPayload(b, session: sessions[b.sessionId], live: live[b.sessionId])
            }
            do {
                let (status, body) = try await transport.post("api/ingest/turns", json: ["turns": turns, "device": device])
                guard (200..<300).contains(status) else {
                    report.failed += 1
                    report.note = "turns: HTTP \(status) \(String(decoding: body.prefix(120), as: UTF8.self))"
                    return
                }
            } catch { report.failed += 1; report.note = "turns: \(error.localizedDescription)"; return }
            cursor = batch.last!.eventRowid
            sync { state.turnCursor = cursor }
            report.turns += batch.count
            save()
            if batch.count < 100 { break }
        }
    }

    /// One turn, in the shape the hub keys on: `source_key` is the session and
    /// the event row, so the same brief twice is one row there.
    static func turnPayload(_ b: StoredBrief, session: WaitingSession?, live: LiveSession?) -> [String: Any] {
        var json: [String: Any] = [
            "session_id": b.sessionId,
            "source_key": "\(b.sessionId):\(b.eventRowid)",
            "at": iso(Date(timeIntervalSince1970: Double(b.atMs) / 1000)),
            "topic": b.topic,
        ]
        func put(_ k: String, _ v: String?) { if let v, !v.isEmpty { json[k] = v } }
        put("headline", b.headline); put("deck", b.deck); put("happened", b.happened)
        put("findings", b.findings); put("solution", b.solution); put("rationale", b.rationale)
        put("next_step", b.nextStep); put("question", b.question); put("risk", b.risk)
        put("branch", b.branch)
        put("cwd", session?.cwd)
        put("agent_title", displayName(session: session, live: live, sessionId: b.sessionId, callsign: b.callsign))
        return json
    }

    /// What the grid calls it, by the grid's own rule, or the brief's callsign
    /// for a session the store no longer lists.
    static func displayName(session: WaitingSession?, live: LiveSession?, sessionId: String, callsign: String?) -> String? {
        if let session { return GridAssembler.tabDisplayName(for: session, live: live) }
        if let live { return GridAssembler.tabDisplayName(live: live, callsign: callsign) }
        if let callsign, !callsign.isEmpty { return callsign }
        return nil
    }

    func knownSessions() -> [String: WaitingSession] {
        guard let store, let rows = try? store.allKnownSessions(limit: 20_000) else { return [:] }
        return Dictionary(rows.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Names

    /// Names are derived, never stored, and Claude Code re-titles a conversation
    /// as it goes; so every full run re-resolves every session the panel
    /// knows and sends the ones that changed.
    func mirrorNames(_ report: inout Report) async {
        let sessions = knownSessions()
        let live = liveSessions()
        let previous = sync { state.names }
        let changed = Self.changedNames(sessions: Array(sessions.values), live: live, previous: previous)
        guard !changed.isEmpty else { return }
        for chunk in stride(from: 0, to: changed.count, by: 200).map({ Array(changed[$0..<min($0 + 200, changed.count)]) }) {
            let names = chunk.map { ["session_id": $0.0, "title": $0.1] }
            do {
                let (status, body) = try await transport.post("api/ingest/names", json: ["names": names, "device": device])
                guard status == 200 else { report.failed += 1; report.note = "names: HTTP \(status)"; return }
                if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let n = obj["renamed"] as? Int { report.renamed += n }
                sync { for (s, t) in chunk { state.names[s] = t } }
            } catch { report.failed += 1; report.note = "names: \(error.localizedDescription)"; return }
        }
    }

    static func changedNames(sessions: [WaitingSession], live: [String: LiveSession],
                             previous: [String: String]) -> [(String, String)] {
        sessions.compactMap { s in
            let title = GridAssembler.tabDisplayName(for: s, live: live[s.sessionId])
            guard !title.isEmpty, previous[s.sessionId] != title else { return nil }
            return (s.sessionId, title)
        }.sorted { $0.0 < $1.0 }
    }

    // MARK: - Heartbeat and state

    func heartbeat(_ note: String) async {
        do {
            _ = try await transport.post("api/heartbeat", json: ["device": device, "note": String(note.prefix(200))])
            sync { state.lastHeartbeatAt = Date(); state.lastHeartbeatNote = note }
        } catch { Self.trace?("heartbeat: \(error.localizedDescription)") }
    }

    /// For the Setup row: when this Mac last spoke to the hub, and what it said.
    public var lastHeartbeat: (at: Date, note: String)? {
        sync {
            guard let at = state.lastHeartbeatAt, let note = state.lastHeartbeatNote else { return nil }
            return (at, note)
        }
    }

    static func load(_ url: URL) -> State {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return s
    }

    func save() {
        let snapshot = sync { state }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }
}
