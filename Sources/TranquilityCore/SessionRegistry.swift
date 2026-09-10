import Foundation

/// What Claude Code itself writes down about each of its live sessions.
///
/// Every session registers a file at `~/.claude/sessions/<pid>.json` and keeps
/// it current — the same registry the harness reads when one session lists or
/// messages another. It carries, first-hand, the three facts this app has
/// until now been INFERRING:
///
/// - `status` — idle or busy, stated by the process itself, where readiness
///   was previously read off a repainting screen or a `claude agents --json`
///   subprocess.
/// - `tmux` — the pane, as `session:@window.%pane`, where addressing a pane
///   previously meant joining `ps` to a tty to `list-panes -a`. That join is
///   where "the session is right here and it couldn't open it" came from: a
///   pid goes stale, the tty is recycled, and three hops each get a chance to
///   be wrong about a session that is sitting there perfectly alive.
/// - `messagingSocketPath` — the session's inbox, recorded here for the day
///   it becomes useful; nothing reads it yet.
///
/// Read-only, and deliberately so. This file is the harness's to write.
///
/// CLAUDE CODE ONLY. Codex keeps its own bookkeeping elsewhere and writes
/// nothing here, so every lookup returns nil for a Codex session and every
/// caller must have a path that survives that — this is a better answer where
/// one exists, never the only answer. A ladder, like `landingDirectory`, not a
/// second mechanism running alongside the first.
public enum SessionRegistry {

    public struct Entry: Sendable, Equatable {
        public let pid: Int
        public let sessionId: String
        public let cwd: String?
        /// "idle" / "busy" as the session itself last reported.
        public let status: String?
        /// `tb-1234abcd:@17.%17` — session, window, pane.
        public let tmux: String?
        public let messagingSocketPath: String?
        public let name: String?
        /// When the session last rewrote this file (epoch ms).
        public let updatedAt: Double?
        /// "interactive" for a person's terminal session, "bg" for a job the
        /// daemon hosts on a pty of its own. The CLI's `--json` spells the
        /// second one "background"; the file spells it "bg". Both are read.
        public var kind: String? = nil
        /// Set on an interactive session that was sent to the background with
        /// the left arrow (Claude Code's agent view): the 8-character id of the
        /// job now standing where the session was. While this is set the CLI
        /// lists the job and hides the session, which is how a working session
        /// vanished from the grid and a blue row with no window took its place
        /// (10 Sep, 6:01 AM).
        public var parkedJobId: String? = nil
        /// The job's own side of that link: an 8-character id equal to the
        /// parent's `parkedJobId`.
        public var jobId: String? = nil
        /// When the process came up (epoch ms), as the file records it.
        public var startedAt: Double? = nil

        /// Just the `%17` — the only part any tmux command needs, and the
        /// part that is stable while a window is renamed or moved.
        public var paneId: String? {
            guard let tmux, let dot = tmux.lastIndex(of: ".") else { return nil }
            let pane = String(tmux[tmux.index(after: dot)...])
            return pane.hasPrefix("%") ? pane : nil
        }

        /// `tb-1234abcd` — needed for `attach`, which addresses sessions.
        public var tmuxSessionName: String? {
            guard let tmux, let colon = tmux.firstIndex(of: ":") else { return nil }
            let name = String(tmux[tmux.startIndex..<colon])
            return name.isEmpty ? nil : name
        }
    }

    /// Where the harness keeps the registry. Not configurable: it is the
    /// harness's own path, and guessing a different one would silently read
    /// nothing forever.
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Every readable entry. Unreadable or half-written files are skipped
    /// rather than failing the sweep — a session rewriting its file while we
    /// read is ordinary, and one bad file must not blind us to fifteen good
    /// ones.
    public static func all(in directory: URL = SessionRegistry.directory) -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name))
            else { return nil }
            return decode(data)
        }
    }

    /// The pure half, so the parsing is testable without a home directory.
    public static func decode(_ data: Data) -> Entry? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["pid"] as? Int,
              let sessionId = obj["sessionId"] as? String, !sessionId.isEmpty
        else { return nil }
        return Entry(pid: pid,
                     sessionId: sessionId,
                     cwd: obj["cwd"] as? String,
                     status: obj["status"] as? String,
                     tmux: obj["tmux"] as? String,
                     messagingSocketPath: obj["messagingSocketPath"] as? String,
                     name: obj["name"] as? String,
                     updatedAt: (obj["updatedAt"] as? NSNumber)?.doubleValue,
                     kind: obj["kind"] as? String,
                     parkedJobId: obj["parkedJobId"] as? String,
                     jobId: obj["jobId"] as? String,
                     startedAt: (obj["startedAt"] as? NSNumber)?.doubleValue)
    }

    /// A session sent to the background is still that session.
    ///
    /// Pressing the left arrow on an empty prompt backgrounds a Claude Code
    /// session and opens its agent view. From then on `claude agents --json`
    /// lists the background JOB (kind "background", busy, blocked, wearing the
    /// session's name) and omits the SESSION, whose process is still alive in
    /// its own tmux pane with its own registry file. Taken at face value that
    /// list put a blue row with no window on the grid: Go to Agent looked for
    /// the job's pane, found none, tried to move it under tmux, and the guard
    /// refused because the job's pty host already held the id. Robert, 10 Sep:
    /// "it says it's already running somewhere ... either restart it, go to
    /// it." The right answer was the pane his session had been in all along.
    ///
    /// So the list is corrected here, at the decode boundary, from the files
    /// the harness itself writes: every job that a live interactive session
    /// has parked is dropped, and if the CLI omitted that session, the session
    /// stands in for it, reported as waiting at the agent view. Its pane comes
    /// from its own registry file, so Go to Agent raises the tab it has always
    /// had; a typed reply is refused, because the terminal is showing the
    /// agent view's task box and the words would land there.
    ///
    /// Only a parent whose pid is alive counts. A job with no live parent is
    /// left exactly as the CLI reported it: that is somebody's dispatched
    /// background session, and this rule has nothing to say about it.
    public static func standingInForParkedJobs(
        _ live: [LiveSession], entries: [Entry], isAlive: (Int) -> Bool,
        trace: ((String) -> Void)? = nil
    ) -> [LiveSession] {
        let parked = entries.filter { $0.parkedJobId != nil && $0.kind != "bg" && isAlive($0.pid) }
        guard !parked.isEmpty else { return live }
        var out = live
        for parent in parked {
            guard let job = parent.parkedJobId, !job.isEmpty else { continue }
            // The job as the CLI saw it (status, start time) and as its own
            // registry file names it (full id). Either may be missing: the
            // CLI drops a stopped job, and a job killed before it wrote its
            // file has no file. The parent's parkedJobId is the one fact that
            // is always there.
            let jobRows = out.filter { $0.isBackground && $0.sessionId.hasPrefix(job) }
            let jobFile = entries.first { $0.kind == "bg" && ($0.jobId == job || $0.sessionId.hasPrefix(job)) }
            let parked = LiveSession.ParkedJob(
                jobId: job,
                sessionId: jobRows.first?.sessionId ?? jobFile?.sessionId,
                status: jobRows.first?.status,
                startedAt: jobRows.first?.startedAt ?? jobFile?.startedAt,
                cwd: jobRows.first?.cwd ?? jobFile?.cwd)
            out.removeAll { $0.isBackground && $0.sessionId.hasPrefix(job) }
            let dropped = jobRows.count
            if out.contains(where: { $0.sessionId == parent.sessionId }) {
                if dropped > 0 {
                    trace?("liveness: dropped job \(job) parked by \(parent.sessionId.prefix(8)), "
                           + "which the CLI still lists")
                }
                continue
            }
            var standIn = LiveSession(pid: parent.pid, sessionId: parent.sessionId,
                                      cwd: parent.cwd, status: "waiting", name: nil,
                                      waitingFor: Readiness.agentView, kind: "interactive",
                                      startedAt: parent.startedAt)
            standIn.parkedJob = parked
            out.append(standIn)
            trace?("liveness: \(parent.sessionId.prefix(8)) is parked in the agent view; "
                   + "standing in for job \(job) (\(dropped) row(s) dropped)")
        }
        return out
    }

    /// The entry for one session id, newest first when a stale file for a
    /// dead pid still names the same session — which happens, because the
    /// registry is keyed by pid and a resumed session gets a new one.
    public static func entry(forSessionId id: String,
                             in directory: URL = SessionRegistry.directory) -> Entry? {
        all(in: directory)
            .filter { $0.sessionId == id }
            .max { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) }
    }
}
