import Foundation

/// Every session this machine has run lately, awake or not.
///
/// Ruled 11 Aug: "They are equally valid agents whether or not they are awake.
/// They do not stop existing once their process ends, and their history should
/// not be invisible or unreachable." The grid until now enumerated PROCESSES —
/// `claude agents --json` joined against the store — so a machine restart
/// emptied it completely, on precisely the morning a list is most wanted.
///
/// So the direction inverts. The transcript directory enumerates, because it is
/// the durable record and Claude Code writes it whether we are watching or not.
/// Liveness becomes a column on a row rather than the gate in front of it.
///
/// Read-only by construction: no store writes, nothing spoken, no synthetic
/// events. This is a display source, not a log source — the rule that keeps
/// "an event is a fact about what happened, and facts do not change" intact.
public enum SessionDiscovery {

    // MARK: - What a row is

    /// Three states, not two, and the third is the one that matters.
    ///
    /// A failed probe is not evidence of absence. Collapsing `unknown` into
    /// `gone` would offer a revive on a session that is merely unproven — and
    /// `claude --resume` on a session that is still running leaves the original
    /// process alive and adds a SECOND live entry under the same id, which
    /// crashed the app twice (06 Aug 14:35, 07 Aug 17:39; see the dedupe note
    /// in the app's `sessionRowsNow`). The verb must have positive evidence.
    public enum Liveness: String, Sendable, Equatable {
        case live, gone, unknown
    }

    public struct Session: Sendable, Equatable {
        public let sessionId: String
        /// Where the session was launched, read from the transcript rather than
        /// decoded from the directory name — see `firstCwd`.
        public let cwd: String?
        public let transcriptPath: String
        public let title: String?
        /// When this agent last moved: the newest timestamp the conversation
        /// itself wrote, with the file's mtime only as the fallback for a tail
        /// holding no dated entry at all. NOT the file's clock — see
        /// `lastMoved(tail:)` for why mtime cannot be trusted to mean this.
        public let lastActivityAt: Date
        /// Whether a user prompt follows the final assistant message. NOT the
        /// same question as "have you heard it", which lives in the cursor and
        /// is a fact about the user rather than the world.
        public let answered: Bool
        public let activity: SessionActivity?
        public let liveness: Liveness
        /// `gone` AND the launch directory still exists. Never true on
        /// `unknown`, and never true when `claude --resume` would land nowhere.
        public let revivable: Bool

        public init(sessionId: String, cwd: String?, transcriptPath: String,
                    title: String?, lastActivityAt: Date, answered: Bool,
                    activity: SessionActivity?, liveness: Liveness, revivable: Bool) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.transcriptPath = transcriptPath
            self.title = title
            self.lastActivityAt = lastActivityAt
            self.answered = answered
            self.activity = activity
            self.liveness = liveness
            self.revivable = revivable
        }

        /// The same row with the process facts joined on. The scan leaves them
        /// at `.unknown`/`false` because it is cached and they are not.
        func with(liveness: Liveness, revivable: Bool) -> Session {
            Session(sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath,
                    title: title, lastActivityAt: lastActivityAt, answered: answered,
                    activity: activity, liveness: liveness, revivable: revivable)
        }

        /// What brings this session back. Nil when it must not be offered.
        /// The resume flag comes from the adapter now — this used to be a
        /// second, independent `["--resume", sessionId]` literal that could
        /// drift from `AgentDefaults`'s, and did not even have the shape to
        /// represent a subcommand-style resume (Codex: `resume <id>`, not a
        /// flag) when that day comes. Every row is Claude Code today, same
        /// scope `SessionLauncher.launch`'s default keeps — this becomes a
        /// per-row adapter lookup when discovery itself goes multi-harness.
        public var reviveCommand: (cwd: String, arguments: [String])? {
            guard revivable, let cwd else { return nil }
            return (cwd, ClaudeCodeAdapter().resumeArguments(sessionId: sessionId))
        }
    }

    /// Counts travel with the rows, because a filter that drops 460 of 504
    /// candidates in silence reads as "that is all of them" — the same lie the
    /// empty panel tells today.
    public struct Result: Sendable {
        public var sessions: [Session] = []
        public var scanned = 0
        /// Excluded as headless: `entrypoint` is `sdk-cli` rather than `cli`.
        public var headless = 0
        /// The transcript carries no `entrypoint` at all, so it was KEPT rather
        /// than dropped — exclusion needs positive evidence. Zero on every file
        /// on this machine as of 11 Aug; counted anyway, because a silent zero
        /// and a silent thousand look identical.
        public var unclassifiable = 0
        /// Dropped by `limit` after ranking, so the caller can say "and more".
        public var beyondLimit = 0
        /// The liveness probe could not answer, so every row is `unknown`.
        public var livenessUnavailable = false
    }

    // MARK: - Scope

    /// A week rather than a day, decided by counting rather than by argument:
    /// on this machine the window holds 31 interactive sessions at 24h and 44
    /// at 7d. Thirteen more rows buys "what I have been doing" over "what I was
    /// doing", which is what makes the case work after a weekend.
    public static let defaultWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Above what any list can be read at. The grid caps far lower; this only
    /// stops the classifier reading the whole archive.
    public static let defaultLimit = 60

    /// Enough to reach the first entry carrying `entrypoint` and `cwd`. The
    /// first lines of a transcript can be bookkeeping (`queue-operation`,
    /// `last-prompt`) which carry neither.
    static let headBytes = 64 * 1024

    /// A single record can be larger than the whole window: a queued prompt
    /// carrying a long payload writes one `queue-operation` line of 200KB, and
    /// two files on this machine open with exactly that, so the first window
    /// held two lines and neither had an `entrypoint`. They were counted
    /// unclassifiable and dropped — correctly, as it happens, since both were
    /// cron sessions, but by luck rather than by rule. One escalation, then the
    /// file is genuinely unreadable and says so.
    static let headBytesEscalated = 2 * 1024 * 1024

    // MARK: - The walk

    /// The disk half, cached; the process half, never.
    ///
    /// This is the "liveness is a column, not a gate" decision earning its
    /// keep. The grid refreshes on every intake tick, and re-walking 505
    /// transcripts each time would be absurd — but the expensive facts (which
    /// sessions exist, what they are called, whether you answered them) change
    /// on the timescale of a conversation, while the cheap one (is a process
    /// behind it) changes in an instant and must never be stale. So the scan is
    /// cached and the liveness join is redone on every call.
    ///
    /// A session that exits therefore turns from a live row into a closed row
    /// on the very next tick, without any disk work at all: it is already in
    /// the cached scan, because the scan does not care whether it was running.
    private final class ScanCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (key: String, at: Date, result: Result)?
        /// The directory is part of the key, not just the window and the cap.
        /// Without it a test archive answers for the real one, which is a bug
        /// waiting to be blamed on the classifier.
        static func key(_ window: TimeInterval, _ limit: Int, _ projects: URL) -> String {
            "\(window)|\(limit)|\(projects.path)"
        }
        /// The last scan for this archive at ANY age, plus whether it is old
        /// enough to be worth redoing. Serving is not the same question as
        /// refreshing, and conflating them is what made the closed rows blink:
        /// returning nothing on expiry emptied the band for the five seconds a
        /// rescan took, every thirty seconds, forever.
        func get(key: String, now: Date, ttl: TimeInterval) -> (result: Result, stale: Bool)? {
            lock.lock(); defer { lock.unlock() }
            guard let value, value.key == key else { return nil }
            let age = now.timeIntervalSince(value.at)
            return (value.result, age >= ttl || age < 0)
        }
        func put(key: String, now: Date, result: Result) {
            lock.lock(); value = (key, now, result); lock.unlock()
        }
        /// One background walk at a time. Without this, every tick of a 1–5s
        /// poll would start another scan of the same archive while the first
        /// was still running.
        private var refreshing: Set<String> = []
        func beginRefresh(key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return refreshing.insert(key).inserted
        }
        func endRefresh(key: String) {
            lock.lock(); refreshing.remove(key); lock.unlock()
        }
        var isRefreshing: Bool {
            lock.lock(); defer { lock.unlock() }; return !refreshing.isEmpty
        }
    }
    private static let scans = ScanCache()

    /// Long enough that the walk is not on the poll's critical path, short
    /// enough that a session started in another terminal shows up while you are
    /// still looking for it.
    public static let scanTTL: TimeInterval = 30

    /// For callers that must not block: the liveness-joined rows IF a scan is
    /// already in hand, and otherwise nothing at all plus a refresh started in
    /// the background.
    ///
    /// The grid refresh runs on the main thread. A cold `discover` walks the
    /// archive and takes about a second and a half on this machine, and a
    /// second and a half of frozen panel is a worse bug than the empty panel
    /// this feature exists to fix. So the first tick after launch shows the
    /// live sessions alone — exactly what shipped before — and the closed rows
    /// arrive on the next one. Nothing is lost by being a tick late to
    /// something that has not moved in hours.
    ///
    /// The liveness join still happens inline on every call, because it is a
    /// cached subprocess result and costs nothing.
    public static func discoverIfScanned(
        window: TimeInterval = defaultWindow,
        limit: Int = defaultLimit,
        now: Date = Date(),
        live: ClaudeAgentsReading = ClaudeAgentsCLI(),
        projects: URL = TranscriptArchive.projectsDirectory,
        titles: TranscriptTitles = TranscriptTitles.shared,
        ttl: TimeInterval = scanTTL
    ) -> Result? {
        let key = ScanCache.key(window, limit, projects)
        let held = scans.get(key: key, now: now, ttl: ttl)

        // Refresh whenever there is nothing or the answer has aged out — but
        // that decision never withholds what we already have.
        if held == nil || held?.stale == true, scans.beginRefresh(key: key) {
            Task.detached(priority: .utility) {
                let fresh = scan(window: window, limit: limit, now: Date(),
                                 projects: projects, titles: titles)
                scans.put(key: key, now: Date(), result: fresh)
                scans.endRefresh(key: key)
            }
        }

        // Stale is fine and nil is not. These are sessions that exited hours
        // ago: a thirty-second-old answer about them is indistinguishable from
        // a current one, while an EMPTY answer is a row disappearing out from
        // under someone who was looking at it. Only a genuinely cold cache —
        // the first tick after launch — returns nothing.
        guard let held else { return nil }
        return join(held.result, live: live)
    }

    /// Wait for any background scan to finish. For tests only.
    ///
    /// A detached scan that outlives its test keeps doing disk I/O while the
    /// next suite runs, and the next suite here measures real-time audio
    /// playback — `SessionDiscoveryTests` sorts immediately before
    /// `TruncationTests`. That made a timing test fail in a way that looked
    /// like a defect in speech and was actually this.
    public static func settleForTesting(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while scans.isRefreshing, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Fill the cache off-main so the first painted grid already has its closed
    /// rows. Without this the panel opens with live sessions alone and they
    /// arrive a few seconds later, which is the same blink in miniature.
    public static func warm(
        window: TimeInterval = defaultWindow,
        limit: Int = defaultLimit,
        projects: URL = TranscriptArchive.projectsDirectory,
        titles: TranscriptTitles = TranscriptTitles.shared
    ) {
        let key = ScanCache.key(window, limit, projects)
        guard scans.get(key: key, now: Date(), ttl: scanTTL) == nil,
              scans.beginRefresh(key: key) else { return }
        let result = scan(window: window, limit: limit, now: Date(),
                          projects: projects, titles: titles)
        scans.put(key: key, now: Date(), result: result)
        scans.endRefresh(key: key)
    }

    public static func discover(
        window: TimeInterval = defaultWindow,
        limit: Int = defaultLimit,
        now: Date = Date(),
        live: ClaudeAgentsReading = ClaudeAgentsCLI(),
        projects: URL = TranscriptArchive.projectsDirectory,
        titles: TranscriptTitles = TranscriptTitles.shared,
        ttl: TimeInterval = scanTTL
    ) -> Result {
        let key = ScanCache.key(window, limit, projects)
        let held = scans.get(key: key, now: now, ttl: ttl)
        let result: Result = {
            if let held, !held.stale { return held.result }
            let scanned = scan(window: window, limit: limit, now: now,
                               projects: projects, titles: titles)
            scans.put(key: key, now: now, result: scanned)
            return scanned
        }()

        return join(result, live: live)
    }

    /// The process half, redone on every call however old the scan is.
    static func join(_ scanned: Result, live: ClaudeAgentsReading) -> Result {
        var result = scanned
        // nil means "could not determine", which is not "none" — the same
        // distinction `ClaudeAgentsReading` documents. Here it makes every row
        // `unknown`, which shows the work and withholds the verb.
        let liveIds = live.sessions().map { Set($0.map(\.sessionId)) }
        result.livenessUnavailable = liveIds == nil
        let fm = FileManager.default
        result.sessions = result.sessions.map { session in
            let liveness: Liveness = {
                guard let liveIds else { return .unknown }
                return liveIds.contains(session.sessionId) ? .live : .gone
            }()
            // A directory that no longer exists is where `--resume` fails with
            // "No conversation found" (BloopAI/vibe-kanban#2993 is the same
            // failure with their filenames). Resolve first, offer second, and
            // resolve it HERE rather than in the scan: a directory can vanish
            // between two ticks and an offer must never outlive its target.
            let landable = session.cwd.map { isDirectory($0, fm) } ?? false
            return session.with(liveness: liveness,
                                revivable: liveness == .gone && landable)
        }
        return result
    }

    /// The disk walk. Everything here is a fact about what was written, so it
    /// is safe to cache; nothing here consults a process.
    static func scan(
        window: TimeInterval,
        limit: Int,
        now: Date,
        projects: URL,
        titles: TranscriptTitles
    ) -> Result {
        var result = Result()
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil) else { return result }

        var candidates: [(URL, Date)] = []
        for project in projectDirs {
            // Immediate children only. A session's subagent traffic lives in
            // `<sessionId>/subagents/*.jsonl` — 7,265 files on this machine
            // against 2,634 sessions — and a subagent is not an agent you can
            // talk to.
            guard let files = try? fm.contentsOfDirectory(
                at: project, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                // mtime stays as the PRE-filter only. An append-only file's
                // clock can only run ahead of its last written timestamp, so
                // nothing inside the real window is lost to this test — but
                // membership and rank are decided by `lastMoved`, below.
                guard now.timeIntervalSince(modified) <= window else { continue }
                candidates.append((file, modified))
            }
        }

        var kept: [Session] = []
        for (url, modified) in candidates.sorted(by: { $0.1 > $1.1 }) {
            result.scanned += 1
            let path = url.path
            guard let head = classifiableHead(of: path) else { continue }

            // The one field that separates a person's session from a robot's,
            // and unlike the tty it is on disk, so it survives the process.
            let entry = entrypoint(head: head)
            if entry == nil { result.unclassifiable += 1 }
            guard !isHeadless(entry) else { result.headless += 1; continue }

            let sessionId = url.deletingPathExtension().lastPathComponent
            let cwd = firstCwd(head: head)
            let tail = SessionActivity.tail(of: path) ?? []
            let moved = lastMoved(tail: tail) ?? modified

            // The window re-applied to the conversation's own clock: a touched
            // ancient transcript wears a fresh mtime — that is exactly the
            // contamination — but its last written entry is still weeks old,
            // and scope is defined by when the agent moved, not by when its
            // file did.
            guard now.timeIntervalSince(moved) <= window else { continue }

            // Liveness and revivability are deliberately absent here: they are
            // process facts, they go stale in seconds, and `discover` joins
            // them on afterwards so this whole walk can be cached.
            kept.append(Session(
                sessionId: sessionId,
                cwd: cwd,
                transcriptPath: path,
                title: titles.latestTitle(transcriptPath: path),
                lastActivityAt: moved,
                answered: isAnswered(tail: tail),
                activity: SessionActivity.classify(tail: tail, modified: modified, now: now),
                liveness: .unknown,
                revivable: false))
        }

        // Ranked by when the agent moved, THEN cut. The old shape cut mid-walk
        // in mtime order, so WHICH sessions survived the cap was decided by the
        // contaminated clock too, not just where they sat. The cost is a tail
        // read for every interactive candidate in the window (~44 on this
        // machine) instead of the first `limit` — bounded by the window, and
        // the walk is cached (see ScanCache), so it is paid once per TTL.
        kept.sort { $0.lastActivityAt > $1.lastActivityAt }
        if kept.count > limit {
            result.beyondLimit = kept.count - limit
            kept.removeLast(kept.count - limit)
        }
        result.sessions = kept
        return result
    }

    /// When the agent last moved, read from inside the file rather than off it.
    ///
    /// The transcript's mtime does not mean this. Claude Code appends
    /// untimestamped bookkeeping (`bridge-session`, `atis-latch`, `last-prompt`,
    /// `ai-title`, `permission-mode`…) when a session is merely opened, resumed,
    /// or bridge-synced, and every such touch bumps the file's clock. Measured
    /// 19 Aug, the first restart this feature lived through: every dead
    /// transcript on the machine had been touched 1–7 hours after its last real
    /// entry, in the order Robert clicked through them afterwards — so the
    /// closed band ranked his BROWSE order and put a session idle since 08:38
    /// at the top. Same disease `SessionActivity.working(since:)` was cured of
    /// on 18 Aug ("the gate was never broken — it was being fed the wrong
    /// clock"); this is the ranking's dose of the same cure.
    ///
    /// The last entry carrying its own timestamp is the newest thing the
    /// conversation actually wrote; bookkeeping carries no timestamp at all, so
    /// under this reading it simply stops counting. Nil when nothing in the
    /// tail is dated — the caller falls back to mtime, which is then the only
    /// clock there is.
    static func lastMoved(tail lines: [String]) -> Date? {
        for line in lines.reversed() {
            guard let entry = json(line),
                  let at = SessionActivity.timestamp(of: entry) else { continue }
            return at
        }
        return nil
    }

    // MARK: - The classifiers, taking lines so every rule is testable

    /// POSITIVE evidence that a session was started by a machine rather than by
    /// a person: `sdk-cli` is `claude -p`, a cron job, our own replay harness.
    /// `cli` is a terminal someone is sitting at.
    ///
    /// Measured over 400 recent transcripts: every cron transcript is
    /// `sdk-cli`, and no cron transcript is `cli`. In a raw 7-day walk of this
    /// machine 460 of 504 transcripts are `sdk-cli` — which is what liveness
    /// used to filter out by ACCIDENT, since a headless run exits the instant
    /// it finishes and never appears in `claude agents --json`.
    ///
    /// The asymmetry is the whole design. Anything else — `cli`, a value a
    /// later Claude Code invents, a file we could not read — is treated as
    /// yours. Excluding on an absence is exactly the mistake the tty filter
    /// made when it "inferred 'nobody is here' from a proxy, and hid real
    /// conversations", and a stray robot row costs one glance where a hidden
    /// session costs the work.
    public static func isHeadless(_ entrypoint: String?) -> Bool { entrypoint == "sdk-cli" }

    /// The same question asked of a transcript on disk, for callers that hold a
    /// path rather than a parsed head — the announcer, in particular.
    ///
    /// Memoised without expiry, because a session's entrypoint is fixed the
    /// moment it starts: it cannot become interactive later. One 64KB read per
    /// session for the life of the process.
    public static func isHeadless(transcriptPath: String?) -> Bool {
        guard let transcriptPath else { return false }
        if let known = origins.get(transcriptPath) { return known }
        let verdict = isHeadless(classifiableHead(of: transcriptPath).flatMap { entrypoint(head: $0) })
        origins.put(transcriptPath, verdict)
        return verdict
    }

    private final class OriginCache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: Bool] = [:]
        func get(_ path: String) -> Bool? {
            lock.lock(); defer { lock.unlock() }; return known[path]
        }
        func put(_ path: String, _ headless: Bool) {
            lock.lock(); known[path] = headless; lock.unlock()
        }
    }
    private static let origins = OriginCache()

    static func entrypoint(head lines: [String]) -> String? {
        for line in lines {
            guard let entry = json(line) else { continue }
            if let value = entry["entrypoint"] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// The FIRST `cwd` in the file: where the session was launched, which is
    /// also what the directory name was slugged from and therefore where a
    /// resume belongs. Later entries carry the directory the agent has wandered
    /// into (a skill's own folder, a subdirectory it is reading), which is not
    /// the session's home.
    ///
    /// Read rather than decoded. `-Users-robertnowell-Projects-kopi-promotions`
    /// cannot be turned back into a path without guessing, because a dash in
    /// the slug is either a separator or a dash in a directory name.
    static func firstCwd(head lines: [String]) -> String? {
        for line in lines {
            guard let entry = json(line) else { continue }
            if let value = entry["cwd"] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Does a user PROMPT follow the final assistant message?
    ///
    /// The naive version of this is wrong in half of all cases, and quietly:
    /// a tool result is written as `"type":"user"`, so "is the last entry a
    /// user entry" answers yes for 241 of the 499 transcripts in a 7-day window
    /// — every one of them an agent mid-loop rather than a user who replied.
    ///
    /// Only two types are the conversation. Everything else — `last-prompt`,
    /// `attachment`, `system`, `ai-title`, `mode`, `bridge-session`, `pr-link`,
    /// whatever is added next — is bookkeeping and is skipped, the same shape
    /// `SessionActivity.classify` uses, so the two cannot drift apart.
    public static func isAnswered(tail lines: [String]) -> Bool {
        for line in lines.reversed() {
            guard let entry = json(line) else { continue }
            switch entry["type"] as? String {
            case "assistant":
                return false                            // the agent spoke last
            case "user":
                return isPrompt(entry)                  // you, or the loop feeding itself
            default:
                continue
            }
        }
        return true      // nothing conversational in the window: nothing is owed
    }

    /// A user entry that is genuinely you typing.
    ///
    /// Excluded: tool results (the loop), hook-injected meta entries (the
    /// harness talking to itself), and sidechain traffic (a subagent, not you).
    static func isPrompt(_ entry: [String: Any]) -> Bool {
        if entry["isMeta"] as? Bool == true { return false }
        if entry["isSidechain"] as? Bool == true { return false }
        guard let message = entry["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return false }
        return blocks.contains {
            ($0["type"] as? String) == "text"
                && !(($0["text"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Reading

    static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// The first `bytes`, split into whole lines. The last line of the window is
    /// dropped when the window was filled: a byte cap lands mid-record, and half
    /// a JSON object is not a record. Mirrors `SessionActivity.tail`, from the
    /// other end.
    static func head(of path: String, bytes: Int = headBytes) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes),
              let window = String(data: data, encoding: .utf8) else { return nil }
        var lines = window.split(separator: "\n").map(String.init)
        if data.count >= bytes, !lines.isEmpty { lines.removeLast() }
        return lines
    }

    /// The head, widened once if the first window held no `entrypoint`. See
    /// `headBytesEscalated` for the case that forced this.
    static func classifiableHead(of path: String) -> [String]? {
        guard let first = head(of: path) else { return nil }
        if entrypoint(head: first) != nil { return first }
        return head(of: path, bytes: headBytesEscalated) ?? first
    }

    static func isDirectory(_ path: String, _ fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
