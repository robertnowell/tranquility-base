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
                     updatedAt: (obj["updatedAt"] as? NSNumber)?.doubleValue)
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
