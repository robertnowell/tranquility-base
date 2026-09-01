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
        /// The human sentence when the turn DIED rather than finished.
        ///
        /// Codex puts a structured `error` on the completion record, so "the
        /// turn ended" and "it ended badly" are one line and not two. Nothing
        /// retries past this record: it IS the turn ending, which is why an
        /// error here needs none of the transient grace Claude Code's
        /// mid-stream error lines get.
        ///
        /// Measured across the 222 rollouts on this machine: 20 failed turns
        /// in 12 sessions, and Codex classifies them itself in
        /// `codex_error_info` (15 `other`, 5 `usage_limit_exceeded`). We read
        /// the SHAPE, never the words, so a failure kind nobody has seen yet
        /// arrives correctly with no code change.
        public var error: String?
        /// The user pressed Esc. The turn is as over as a completion, and
        /// carries no `last_agent_message` to record.
        public var aborted: Bool

        public init(turnId: String, lastAgentMessage: String? = nil,
                    error: String? = nil, aborted: Bool = false) {
            self.turnId = turnId
            self.lastAgentMessage = lastAgentMessage
            self.error = error
            self.aborted = aborted
        }

        /// Whether this turn ended in a state a person has to do something
        /// about. `aborted` is not one: the person who pressed Esc knows.
        public var failed: Bool { error != nil }
    }

    /// What ONE line of a rollout says, which is the only thing that knows
    /// this format.
    ///
    /// Split out on 01 Sep, after the lamp logic grew its own hand-rolled
    /// copy of the same JSON walk. Robert: *"is our architecture defensible,
    /// simple, and can we extend it to other errors in the future?"* Two
    /// readers of one undocumented, actively-migrating format is how they
    /// drift apart, and the second reader had already missed `turn_aborted` —
    /// 30 of them on this machine — which this one had handled since August.
    ///
    /// So there is one decoder now, with two shapes of consumer: `parse`
    /// folds it forward over a whole file, and `SessionActivity` walks it
    /// backwards from the tail until a line says something.
    public enum Record: Sendable, Equatable {
        case meta(SessionMeta)
        /// A turn began and has not been closed on this line.
        case turnStarted(turnId: String)
        /// A turn ended — completed, failed, or aborted. `TurnCompletion`
        /// says which.
        case turnEnded(TurnCompletion)
        /// Real conversation content: a human or the model actually wrote
        /// this, at this line's timestamp.
        case content(Message)
        /// The session MOVED here, but wrote nothing a person would read:
        /// a tool call, its output, a reasoning item, an item completing.
        ///
        /// Two consumers want opposite things from these, which is why they
        /// are their own case rather than folded into either neighbour. A
        /// summary or a delivery check wants only `content` — a tool call is
        /// not something anybody said. A LAMP wants exactly this: it is proof
        /// the agent is working, and on a real rollout it is most of the
        /// file. Counted as `ignored`, a session in a twenty-minute tool loop
        /// dated its evidence from the last sentence it spoke and went amber
        /// while it was busy — the mirror of the bug we started from.
        ///
        /// Claude Code's side has always had this: `hasToolUse` on an
        /// assistant entry means the turn is still running.
        case activity
        /// A record type this format has and this type models nothing for —
        /// `compacted`, `world_state`, `turn_context`, `session_meta` without
        /// an id. Recognised and passed over, which is different from
        /// unreadable.
        case ignored
        /// Not JSON, or JSON without the two fields every record has. The
        /// one failure worth counting: a schema change that silently empties
        /// every field must not look like a quiet session.
        case undecodable
    }

    /// Decode one line. Pure, total, and the only place that knows what a
    /// rollout record looks like.
    public static func record(_ line: some StringProtocol) -> Record {
        guard let data = String(line).data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = row["type"] as? String,
              let payload = row["payload"] as? [String: Any]
        else { return .undecodable }

        switch type {
        case "session_meta":
            guard let id = payload["id"] as? String else { return .ignored }
            return .meta(SessionMeta(sessionId: id, cwd: payload["cwd"] as? String,
                                     cliVersion: payload["cli_version"] as? String))

        case "event_msg":
            guard let kind = payload["type"] as? String else { return .ignored }
            guard let turnId = payload["turn_id"] as? String else {
                // Real events that carry no turn id — `token_count`,
                // `item_completed` on some versions. Movement, not nothing.
                return ["token_count", "item_completed"].contains(kind) ? .activity : .ignored
            }
            switch kind {
            case "task_started", "turn_started":
                return .turnStarted(turnId: turnId)
            case "item_completed", "token_count":
                return .activity
            case "task_complete":
                return .turnEnded(TurnCompletion(
                    turnId: turnId,
                    lastAgentMessage: payload["last_agent_message"] as? String,
                    error: humanMessage(in: payload["error"])))
            case "turn_aborted", "task_aborted":
                return .turnEnded(TurnCompletion(turnId: turnId, aborted: true))
            default:
                return .ignored
            }

        case "response_item":
            guard payload["type"] as? String == "message",
                  let role = payload["role"] as? String,
                  let content = payload["content"] as? [[String: Any]]
            else {
                // `reasoning`, `custom_tool_call`, `custom_tool_call_output`:
                // nothing to read, but the session plainly moved. On the
                // rollout this was measured against, 1,198 of 2,485 lines.
                return .activity
            }
            guard role == "user" || role == "assistant" else { return .activity }
            // Both `input_text` (user) and `output_text` (assistant)
            // carry the field under the same key.
            let text = content.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { return .ignored }
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
                return .ignored
            }
            return .content(Message(role: role, text: text))

        default:
            return .ignored
        }
    }

    /// The sentence a person should read, out of whatever Codex put in
    /// `error`.
    ///
    /// A quarter of the failures on this machine carry the API's entire JSON
    /// body as the message, so the row read `{"type"` — the useful sentence
    /// ("The 'gpt-5.6-sol' model is not supported when using Codex with a
    /// ChatGPT account.") was nested two levels inside it. Unwrapped here,
    /// once, rather than by every surface that displays an error.
    static func humanMessage(in error: Any?) -> String? {
        guard let error = error as? [String: Any],
              let raw = error["message"] as? String, !raw.isEmpty else { return nil }
        guard raw.hasPrefix("{"), let data = raw.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return raw }
        if let inner = body["error"] as? [String: Any],
           let message = inner["message"] as? String, !message.isEmpty { return message }
        if let message = body["message"] as? String, !message.isEmpty { return message }
        return raw
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
            switch record(line) {
            case .meta(let found):
                // First one only: a forked/sub-agent rollout can carry a
                // second `session_meta` for the child thread (observed on
                // this machine, `forked_from_id`/`parent_thread_id` present)
                // — the file's own identity is the first record, always.
                if meta == nil { meta = found }
            case .turnStarted(let turnId):
                openTurns.insert(turnId)
            case .turnEnded(let completion):
                // `remove` on an absent element is a documented no-op, so a
                // turn whose start was never seen closes safely too.
                openTurns.remove(completion.turnId)
                completions.append(completion)
            case .content(let message):
                messages.append(message)
            case .activity, .ignored:
                continue
            case .undecodable:
                skipped += 1
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
