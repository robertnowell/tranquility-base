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
    /// with visible text, from a human or the assistant. Reasoning items
    /// (`encrypted_content`, no plain text) and tool-call items are not
    /// turned into one of these; there is nothing here for a summary or a
    /// delivery check to read. Neither is `developer`-role content: sampled
    /// across 614 real occurrences on this machine, every one is injected
    /// system context (output-style instructions, permission-profile XML,
    /// multi-agent-mode preambles) — the same category `<environment_context>`
    /// exists to strip, never anything a human or TB typed. Nor is
    /// `agent_message` turned into one: a real payload type (142 occurrences),
    /// but its own `author`/`recipient` fields and "Message Type: FINAL_ANSWER
    /// / NEW_TASK" framing show it is Codex's own inter-agent routing
    /// protocol, not a conversational turn — deliberately excluded, not
    /// missed (gate finding, 21 Aug; the exclusion looked like a gap until
    /// a real example showed what it actually is).
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
        /// OR `task_aborted` yet — the busy/idle signal this harness has no
        /// `agents --json` equivalent for (`HarnessCapabilities.
        /// registersWithLiveness == false`), read from the one ground truth
        /// that does exist. NOT a liveness signal on its own: a process
        /// killed mid-turn (no completion, no abort — 42/192 real rollouts
        /// on this machine) reads exactly like a session still working,
        /// because from the rollout's own record, it is indistinguishable —
        /// closing that gap needs `processAlive` or rollout mtime at the
        /// call site, which this pure parser has no way to know (gate
        /// finding, 21 Aug: unhandled `turn_aborted` alone made 55/192 real
        /// rollouts, 29%, read as falsely busy before this fix).
        public var isBusy: Bool
        /// Lines this parse could not decode at all — not a record type
        /// recognized-and-ignored (`compacted`, `world_state`, ...), a line
        /// that failed to become JSON, or JSON missing `type`/`payload`.
        /// Zero on every real rollout on this machine today, but the file
        /// this repo's own `TranscriptArchive`/`ClaudeAgentsCLI` lesson
        /// applies here too: a schema change silently emptying every field
        /// must be visible somewhere, not indistinguishable from "nothing
        /// happened in this session" (gate finding, 21 Aug).
        public var skippedLines: Int

        public init(meta: SessionMeta? = nil, completions: [TurnCompletion] = [],
                   messages: [Message] = [], isBusy: Bool = false, skippedLines: Int = 0) {
            self.meta = meta
            self.completions = completions
            self.messages = messages
            self.isBusy = isBusy
            self.skippedLines = skippedLines
        }
    }

    /// Parse one already-read rollout. A RECOGNIZED-type line this cannot
    /// otherwise decode is skipped, not fatal — `compacted`, `world_state`,
    /// `turn_context`, `inter_agent_communication_metadata` all appear on
    /// real rollouts on this machine and carry nothing this type models; a
    /// version that adds a new record type tomorrow costs nothing here
    /// either. A line that fails to decode AT ALL increments `skippedLines`
    /// rather than vanishing silently.
    public static func parse(_ text: String) -> Parsed {
        var meta: SessionMeta?
        var completions: [TurnCompletion] = []
        var messages: [Message] = []
        var openTurns = Set<String>()
        var skipped = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = row["type"] as? String,
                  let payload = row["payload"] as? [String: Any]
            else { skipped += 1; continue }

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
                } else if kind == "turn_aborted" {
                    // The user hit Esc. No completion to record (there is no
                    // `last_agent_message` on this event), but the turn is
                    // just as over as a `task_complete` — `openTurns.remove`
                    // on an absent element is a documented no-op, so this is
                    // safe even if `task_started` was never seen either.
                    openTurns.remove(turnId)
                }

            case "response_item":
                guard payload["type"] as? String == "message",
                      let role = payload["role"] as? String,
                      let content = payload["content"] as? [[String: Any]]
                else { continue }
                guard role == "user" || role == "assistant" else { continue }
                // Both `input_text` (user) and `output_text` (assistant)
                // carry the field under the same key.
                let text = content.compactMap { $0["text"] as? String }.joined()
                guard !text.isEmpty else { continue }
                // Codex's own injected `<environment_context>` (cwd, shell,
                // permission profile as XML) — not anything a human or TB
                // ever typed. Found at the first user-message position of a
                // turn in a live probe, but that is not where it always
                // sits: measured across 192 real rollouts, the SAME wrapper
                // recurs at later positions too (one file only at message
                // #22; several appear it more than once) — every occurrence
                // is filtered, not just a first-of-turn heuristic (gate
                // finding, 21 Aug — the earlier doc comment claimed
                // "first" and was wrong). The closing-tag check guards
                // against the one real risk: someone pasting a snippet of
                // rollout debugging output that happens to START with the
                // same literal string as genuine content.
                if role == "user", text.hasPrefix("<environment_context>"),
                   text.contains("</environment_context>") {
                    continue
                }
                messages.append(Message(role: role, text: text))

            default:
                continue
            }
        }
        return Parsed(meta: meta, completions: completions, messages: messages,
                      isBusy: !openTurns.isEmpty, skippedLines: skipped)
    }

    // MARK: - Filesystem

    public static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    /// Where Codex writes one empty `<threadId>.lock` file per thread, the
    /// moment the thread is created — found live, 26 Aug, chasing a fresh
    /// Codex launch that never registered: `sessionsDirectory`'s own
    /// rollout file does not exist until the FIRST turn completes, so
    /// polling it for a brand-new, message-less launch waits forever. This
    /// directory is the one place a thread id is knowable before that.
    ///
    /// The lock has no `cwd` in it (a bare UUID filename) — unlike a
    /// rollout, it cannot say WHICH directory a new thread belongs to, only
    /// THAT one now exists. `awaitCodexRegistration` accepts that trade the
    /// same way Claude Code's own registration already does: "the newest
    /// one that appeared since we launched" is the trust model both share,
    /// not a guarantee.
    public static var threadWriterLocksDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/thread-writer-locks")
    }

    /// Every thread id with a lock on disk right now, newest first — a
    /// plain directory listing, stripped of `.lock`. Not cached, not
    /// windowed: unlike `discoverCodex`'s archive walk (which parses every
    /// kept rollout's full content), this is one `contentsOfDirectory` call
    /// plus a per-file mtime stat, cheap enough to poll every half-second
    /// rather than every two.
    ///
    /// Newest-first, not just "new since known": this machine can have
    /// several Codex processes creating threads at once (this repo's own
    /// multi-session drills among them), so on a poll where more than one
    /// lock is new, the most recently created is the one this launch most
    /// likely started — an ordering, not a guarantee, the same trust level
    /// `awaitRegistration`'s own "first new id" already accepts for Claude
    /// Code.
    public static func liveThreadIds(locks: URL = threadWriterLocksDirectory) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: locks.path) else { return [] }
        return names.filter { $0.hasSuffix(".lock") }
            // A thread id, not any lock: found live, this same day, sharing
            // this directory with `.coordination.lock` — a stable file with
            // no thread behind it at all. UUID-shaped only.
            .filter { UUID(uuidString: String($0.dropLast(5))) != nil }
            .compactMap { name -> (String, Date)? in
                let modified = (try? fm.attributesOfItem(atPath: locks.appendingPathComponent(name).path)[.modificationDate] as? Date) ?? nil
                return modified.map { (String(name.dropLast(5)), $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
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
