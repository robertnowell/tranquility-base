import Foundation

/// What was actually said, per turn, from either harness.
///
/// A hub's turn block is a projection of the `brief` table: a headline, a deck,
/// what was found, what is proposed. Good, and lossy, and with no way down to
/// the source. The transcript is on the same disk and nothing links to it, so a
/// summary on a hub is a claim you have to take on faith.
///
/// **The whole readable conversation is 1.4% of the bytes.** Measured on a real
/// 401-turn session: 138.9 MB of log, of which the prompts and the assistant's
/// prose are 1.9 MB. The rest is tool calls and their results, which is the
/// terminal scrollback nobody can read and the reason the log is not already the
/// answer. So this extracts the 1.4% and never the rest.
///
/// **It is a projection too, not a cache.** No file is written and nothing has
/// to be rebuilt: the hub asks at render time for the turns it is about to
/// show. A cache would be one more thing that can disagree with the transcript,
/// and this week has been about removing exactly that.
///
/// **Bounded by bytes, not by turns**, following the measurement already made
/// for `TranscriptSearchText`: bounding by turns needs a JSON parse per line and
/// costs more than a byte bound while finding less. The tail is what a hub
/// shows, so the tail is what is read.
///
/// The parsing entry points are pure and take text, for the reason
/// `CodexRollout` gives for the same choice: a fixture is a string, and a test
/// that needs 192 real files on disk is a test that only runs here.
public enum TurnText {

    public struct Turn: Sendable, Equatable {
        /// What the person asked. Empty when a turn began some other way.
        public let prompt: String
        /// What the agent said back, in prose. Never a tool call or its result.
        public let prose: String

        public init(prompt: String, prose: String) {
            self.prompt = prompt
            self.prose = prose
        }

        /// A turn nobody would read is not worth showing under a brief.
        public var isEmpty: Bool {
            prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 2 MB of tail. The same cap `TranscriptSearchText` measured its way to,
    /// for the same reason: past it the cost keeps climbing and the benefit does
    /// not. A hub renders a handful of turns and they are the last ones.
    public static let byteCap = 2 << 20

    // MARK: - Claude Code

    /// One turn per user message that a PERSON wrote.
    ///
    /// The distinction that matters is in the record, not in the role: a tool's
    /// output comes back as `type: "user"` too. A real prompt carries string
    /// content, or content blocks that are not `tool_result`, and never a
    /// `toolUseResult`. Getting this wrong does not fail loudly; it fills a hub
    /// with file listings.
    public static func claudeCode(jsonl: String, limit: Int) -> [Turn] {
        var turns: [Turn] = []
        var prompt = ""
        var prose: [String] = []
        var started = false

        func close() {
            guard started else { return }
            let t = Turn(prompt: prompt, prose: prose.joined(separator: "\n\n"))
            if !t.isEmpty { turns.append(t) }
            prompt = ""; prose = []
        }

        for line in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let row = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] else { continue }
            let type = row["type"] as? String ?? ""
            guard type == "user" || type == "assistant" else { continue }
            let message = row["message"] as? [String: Any] ?? [:]

            if type == "user" {
                if row["toolUseResult"] != nil { continue }
                let said = humanText(message["content"])
                if said.isEmpty { continue }
                close()
                started = true
                prompt = said
            } else if started {
                let text = assistantText(message["content"])
                if !text.isEmpty { prose.append(text) }
            }
        }
        close()
        return Array(turns.suffix(limit))
    }

    /// String content, or the text blocks of a content array. A `tool_result`
    /// block anywhere in it means this was the harness talking, not a person.
    static func humanText(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = content as? [[String: Any]] else { return "" }
        if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return "" }
        return blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text blocks only. `tool_use` and `thinking` are how the work happened,
    /// not what was said about it.
    static func assistantText(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Codex

    /// Codex already separates what was said from what was done.
    ///
    /// `CodexRollout.Record` distinguishes `content`, which its own comment
    /// defines as "a human or the model actually wrote this", from the tool
    /// calls and reasoning items it files as ignored. So there is no second
    /// filter to write here and no second place for one to be wrong; this only
    /// has to group.
    /// Codex injects its own scaffolding as `user` messages.
    ///
    /// The AGENTS.md preamble, `<environment_context>`, `<image name=…>`, a
    /// `<subagent_notification>`: all arrive with role `user`, so role alone
    /// says "a person typed this" when nobody did. Measured across 60 real
    /// rollouts, every one of them opens with an XML-ish tag or the AGENTS.md
    /// heading, and every real prompt is plain prose.
    ///
    /// Stripped rather than dropped, because a person attaching an image sends
    /// one message carrying both the tag and their sentence; dropping it would
    /// lose the sentence. What is left after the wrappers come off is what they
    /// said, and nothing left means they said nothing.
    static func humanPart(_ text: String) -> String {
        var t = text
        if t.hasPrefix("# AGENTS.md instructions for") { return "" }
        while true {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.hasPrefix("<"),
                  let close = s.firstIndex(of: ">") else { break }
            let tag = s[s.index(after: s.startIndex)..<close]
                .prefix(while: { !$0.isWhitespace && $0 != "/" })
            guard !tag.isEmpty else { break }
            if let end = s.range(of: "</\(tag)>") {
                t = String(s[end.upperBound...])
            } else {
                t = String(s[s.index(after: close)...])
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func codex(messages: [CodexRollout.Message], limit: Int) -> [Turn] {
        var turns: [Turn] = []
        var prompt = ""
        var prose: [String] = []
        var started = false

        func close() {
            guard started else { return }
            let t = Turn(prompt: prompt, prose: prose.joined(separator: "\n\n"))
            if !t.isEmpty { turns.append(t) }
            prompt = ""; prose = []
        }

        for m in messages {
            let text = m.role == "user"
                ? humanPart(m.text)
                : m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if m.role == "user" {
                close()
                started = true
                prompt = text
            } else if started, m.role != "developer" {
                prose.append(text)
            }
        }
        close()
        return Array(turns.suffix(limit))
    }

    // MARK: - From disk

    /// The last `limit` turns a session said, whichever harness it ran under.
    ///
    /// Claude Code first because its transcript path is knowable from the
    /// session id; Codex is asked only when that finds nothing, so a session
    /// that has both never gets two answers.
    public static func forSession(_ sessionId: String, limit: Int = 3,
                                  home: URL = FileManager.default
                                      .homeDirectoryForCurrentUser) -> [Turn] {
        if let path = claudeTranscript(for: sessionId, home: home),
           let text = tail(of: path) {
            let turns = claudeCode(jsonl: text, limit: limit)
            if !turns.isEmpty { return turns }
        }
        if let parsed = CodexRollout.parse(
            sessionId: sessionId,
            sessions: home.appendingPathComponent(".codex/sessions", isDirectory: true)) {
            return codex(messages: parsed.messages, limit: limit)
        }
        return []
    }

    /// `~/.claude/projects/<slugged-cwd>/<session>.jsonl`. The project directory
    /// is not derivable from the id, so this looks for the file by name.
    static func claudeTranscript(for sessionId: String, home: URL) -> URL? {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return nil }
        for d in dirs {
            let f = d.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    /// The last `byteCap` bytes, starting at a line boundary.
    ///
    /// A transcript is append-only and a hub shows its end, so the tail is the
    /// whole answer. The first partial line is dropped rather than repaired: a
    /// half-decoded JSON object is not a turn, and one missing turn at the top
    /// of a bounded read is invisible where a corrupted one is not.
    static func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(byteCap) ? size - UInt64(byteCap) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard start > 0, let nl = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: nl)...])
    }
}
