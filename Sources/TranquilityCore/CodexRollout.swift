import Foundation

/// Codex's own transcript, read the way this repo already reads Claude
/// Code's: FOUND, not derived, and leniently — the exact discipline
/// `TranscriptArchive` and `ClaudeAgentsCLI.decodeSessions` both learned the
/// hard way (a hand-rolled path encoding that drifted; one bad row nilling
/// an entire probe). Fixture-tested against the real rollouts on this
/// machine (192 at last count, six versions from 0.133.0-alpha.1 to
/// 0.149.0) rather than against an invented shape, because the schema
/// already moved once in that window: `session_meta.payload.session_id` is
/// absent on the oldest files here — `id` is the field present on every one
/// sampled, and the field this reads.
public enum CodexRollout {
    /// What `session_meta` carries. `id`, never `session_id`: the latter
    /// was added to the schema after some rollouts on this machine were
    /// already written, `id` was not.
    public struct SessionMeta: Sendable, Equatable {
        public var sessionId: String
        public var cwd: String?
        public var cliVersion: String?
    }

    /// One completed turn's ground truth. `lastAgentMessage` needs no
    /// `response_item` scanning at all — the event carries the answer
    /// directly, which is simpler than the equivalent Claude Code needs
    /// (walking the transcript for the last assistant message).
    public struct TurnCompletion: Sendable, Equatable {
        public var turnId: String
        public var lastAgentMessage: String?
    }

    /// One `response_item` carrying real conversation content — a message
    /// with visible text, from any role. Reasoning items (`encrypted_content`,
    /// no plain text) and tool-call items are not turned into one of these;
    /// there is nothing here for a summary or a delivery check to read.
    public struct Message: Sendable, Equatable {
        public var role: String
        public var text: String
    }

    /// Everything one rollout file's lines decode to. Pure and synchronous —
    /// the caller supplies the text, this makes no filesystem call, which is
    /// what makes it fixture-testable without 192 real files on disk.
    public struct Parsed: Sendable {
        public var meta: SessionMeta?
        public var completions: [TurnCompletion]
        public var messages: [Message]
        /// A `task_started` has been seen with no matching `task_complete`
        /// yet — the busy/idle signal this harness has no `agents --json`
        /// equivalent for (`HarnessCapabilities.registersWithLiveness ==
        /// false`), read from the one ground truth that does exist.
        public var isBusy: Bool

        public init(meta: SessionMeta? = nil, completions: [TurnCompletion] = [],
                   messages: [Message] = [], isBusy: Bool = false) {
            self.meta = meta
            self.completions = completions
            self.messages = messages
            self.isBusy = isBusy
        }
    }

    /// Parse one already-read rollout. A line this cannot decode is
    /// skipped, not fatal — `compacted`, `world_state`, `turn_context`,
    /// `inter_agent_communication_metadata` all appear on real rollouts on
    /// this machine and carry nothing this type models; a version that adds
    /// a new record type tomorrow costs nothing here either.
    public static func parse(_ text: String) -> Parsed {
        var meta: SessionMeta?
        var completions: [TurnCompletion] = []
        var messages: [Message] = []
        var openTurns = Set<String>()

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = row["type"] as? String,
                  let payload = row["payload"] as? [String: Any]
            else { continue }

            switch type {
            case "session_meta":
                // First one only: a forked/sub-agent rollout can carry a
                // second `session_meta` for the child thread (observed on
                // this machine, `forked_from_id`/`parent_thread_id` present)
                // — the file's own identity is the first record, always.
                guard meta == nil, let id = payload["id"] as? String else { continue }
                meta = SessionMeta(sessionId: id, cwd: payload["cwd"] as? String,
                                  cliVersion: payload["cli_version"] as? String)

            case "event_msg":
                guard let kind = payload["type"] as? String,
                      let turnId = payload["turn_id"] as? String else { continue }
                if kind == "task_started" {
                    openTurns.insert(turnId)
                } else if kind == "task_complete" {
                    openTurns.remove(turnId)
                    completions.append(TurnCompletion(
                        turnId: turnId, lastAgentMessage: payload["last_agent_message"] as? String))
                }

            case "response_item":
                guard payload["type"] as? String == "message",
                      let role = payload["role"] as? String,
                      let content = payload["content"] as? [[String: Any]]
                else { continue }
                // Both `input_text` (user, developer) and `output_text`
                // (assistant) carry the field under the same key.
                let text = content.compactMap { $0["text"] as? String }.joined()
                guard !text.isEmpty else { continue }
                // The FIRST user-role message of a turn is Codex's own
                // injected `<environment_context>` (cwd, shell, permission
                // profile as XML) — not anything a human or TB ever typed.
                // Real conversation content, never this wrapper alone.
                if role == "user", text.hasPrefix("<environment_context>") { continue }
                messages.append(Message(role: role, text: text))

            default:
                continue
            }
        }
        return Parsed(meta: meta, completions: completions, messages: messages,
                      isBusy: !openTurns.isEmpty)
    }

    // MARK: - Filesystem

    public static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    /// The rollout file for one thread id — FOUND from the filename Codex
    /// itself writes (`rollout-<timestamp>-<threadId>.jsonl`), not derived
    /// from a guessed directory layout the way `TranscriptArchive` has no
    /// choice but to walk Claude Code's cwd-named directories. A thread id
    /// is unique, so a suffix match is unambiguous and never needs to open
    /// a single file to find the right one.
    public static func rolloutPath(
        forSessionId id: String, sessions: URL = sessionsDirectory
    ) -> String? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: sessions, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return nil }
        let suffix = "-\(id).jsonl"
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) {
            return url.path
        }
        return nil
    }

    /// Read and parse the rollout for one thread id in one call — nil when
    /// no file exists yet (a thread that has never taken a turn) or cannot
    /// be read, a real and tolerated state, the same as
    /// `TranscriptArchive.transcriptPath` returning nil.
    public static func parse(sessionId: String, sessions: URL = sessionsDirectory) -> Parsed? {
        guard let path = rolloutPath(forSessionId: sessionId, sessions: sessions),
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        return parse(text)
    }
}
