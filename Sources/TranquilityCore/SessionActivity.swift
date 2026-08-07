import Foundation

/// What a session is doing right now, read from its transcript.
///
/// Two questions the grid could not answer before this (Robert, 06 Aug): "is
/// this agent working, or just sitting there?" and "did this one die on an
/// error while I wasn't looking?" Both are answerable from the same place —
/// the tail of the session's JSONL — because Claude Code writes every turn,
/// tool call, and API failure into it as it happens.
///
/// Deliberately NOT hook-driven. Measured on this machine's archive: a turn
/// that dies on a usage limit fires no Stop hook in 9 of 10 cases, so an
/// event-driven design would be blind to exactly the case that matters most.
/// Polling the tail is the only honest path.
public enum SessionActivity: Equatable, Sendable {
    /// The agent has work in hand: a prompt it has not answered, a tool call
    /// in flight, or a turn still being written.
    case working
    /// The agent stopped on an error it cannot get past on its own.
    case blocked(reason: String)
    /// Alive, turn complete, nothing in flight.
    case idle

    /// How much of the file's end to read. Transcripts run to hundreds of
    /// megabytes; the last few entries are all that can possibly matter, and
    /// 64KB comfortably holds them even when one entry is a large tool result.
    static let tailBytes = 64 * 1024

    /// How long a self-healing error gets to heal before it lights the lamp.
    /// One poll interval plus headroom: long enough that an automatic retry
    /// finishes first, short enough that a real outage is not hidden.
    static let transientGrace: TimeInterval = 25

    /// The error classes Claude Code retries by itself. Matched on the text
    /// because that is what the transcript carries — and deliberately a
    /// closed list: anything unrecognised is treated as needing a human,
    /// because failing toward "tell him" is the safe direction.
    static func isTransient(_ reason: String) -> Bool {
        let text = reason.lowercased()
        // A usage or session limit is never transient, whatever else the
        // sentence says ("…resets 8pm. Try again later." contains transient
        // copy) — so the blocking phrases are checked first. They are PHRASES,
        // not words: a first version matched bare "limit", which swallowed
        // "temporarily limiting requests" — the commonest transient error of
        // all — and would have lit amber for it every time.
        for blocking in ["session limit", "reached your", "hit your",
                         "usage-credits", "quota", "switch models"]
        where text.contains(blocking) { return false }
        for transient in ["overloaded", "529", "temporarily", "connection closed",
                          "socket", "enotfound", "econnreset", "etimedout",
                          "unable to connect", "rate limiting", "try again",
                          // Added after running the classifier over the real
                          // archive: 31 of 288 errors matched nothing and so
                          // lit amber at once. These are the stream-level
                          // hiccups among them. The rest of that tail —
                          // invalid API key, login expired, prompt too long —
                          // stays unrecognised ON PURPOSE: every one of them
                          // does need a human.
                          "mid-response", "mid-stream", "idle timeout",
                          "could not be processed"]
        where text.contains(transient) { return true }
        return false
    }

    /// Transcript timestamps carry fractional seconds ("…T16:40:28.887Z").
    /// Parsed with a formatter built per call rather than a shared static —
    /// ISO8601DateFormatter is not Sendable, and this runs off the poller.
    static func timestamp(of entry: [String: Any]) -> Date? {
        guard let raw = entry["timestamp"] as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    /// A `working` verdict older than this is not believable — the process is
    /// gone, or a tool call hung days ago. Prevents a lamp stuck on blue for
    /// a session nobody will ever come back to.
    static let freshness: TimeInterval = 15 * 60

    /// The last turn boundary the hooks recorded for a session.
    ///
    /// `UserPromptSubmit` and `Stop` ARE the turn's edges — that is what those
    /// hooks mean, not an inference from something else. This is the only
    /// authoritative statement of "the agent has work and has not finished",
    /// and it is what the transcript alone cannot supply (see `classify`).
    public struct TurnBoundary: Equatable, Sendable {
        public let kind: HookEventKind
        public let at: Date
        public init(kind: HookEventKind, at: Date) {
            self.kind = kind
            self.at = at
        }
    }

    /// Classify a session from its transcript, with the hooks resolving the
    /// one verdict the transcript cannot settle on its own. Returns nil when
    /// the file cannot be read at all — the caller keeps whatever it had
    /// rather than inventing a state from an absent file.
    public static func read(
        transcriptPath: String, boundary: TurnBoundary? = nil, now: Date = Date()
    ) -> SessionActivity? {
        guard let tail = tail(of: transcriptPath) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date
        return classify(tail: tail, modified: modified, boundary: boundary, now: now)
    }

    /// The decision itself, taking lines rather than a path so every rule
    /// below is testable without a filesystem.
    /// Precedence, stated once because two sources of truth is exactly how a
    /// lamp starts lying:
    ///
    /// 1. A transcript error wins outright. The hooks are measurably blind to
    ///    it — a turn that dies on a usage limit fires no Stop in 9 of 10
    ///    cases on this machine's archive.
    /// 2. A positive transcript observation (a tool call in flight, a prompt
    ///    with no answer under it) wins next. The hooks cannot see inside a
    ///    turn, so they have nothing to add and must not contradict it.
    /// 3. Only `idle` is genuinely ambiguous — a finished turn and a mid-turn
    ///    pause after prose are the same shape in the file — and that is the
    ///    case the boundary settles. Measured across 238 turns: the transcript
    ///    alone reads idle for 9.8% of the time an agent is actually working,
    ///    in 69 windows long enough for a poll to land inside one.
    ///
    /// The freshness gate applies either way: a prompt with no Stop after it
    /// would otherwise hold a lamp blue forever on a session that crashed.
    static func classify(
        tail: [String], modified: Date?, boundary: TurnBoundary? = nil, now: Date = Date()
    ) -> SessionActivity {
        // Walk backwards to the first entry that says anything about the
        // conversation. system/attachment/summary lines are bookkeeping —
        // Claude Code writes several of them AFTER an error, which is why
        // "the last line" is the wrong question to ask.
        for line in tail.reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = entry["type"] as? String

            if entry["isApiErrorMessage"] as? Bool == true {
                let reason = text(of: entry)
                // Not every error needs you. Measured on this machine's
                // archive: 110 of 286 are the self-healing kind (529
                // overloaded, ENOTFOUND, a socket closed mid-response) that
                // Claude Code retries on its own, against 176 that genuinely
                // sit until a human acts. Lighting amber for the first kind
                // would teach the eye to ignore amber, which costs more than
                // the lamp is worth. So a transient error must SURVIVE a
                // grace period as the tail before it earns the lamp — if the
                // retry works, the tail moves on and it never lights at all.
                if isTransient(reason), let at = timestamp(of: entry),
                   now.timeIntervalSince(at) < transientGrace {
                    return .idle
                }
                return .blocked(reason: reason)
            }
            switch type {
            case "assistant":
                // A turn that ends in a tool call is still running. One that
                // ends in prose LOOKS finished — but mid-turn prose is the
                // same shape, so that verdict is the ambiguous one and the
                // hooks get the final word on it.
                return hasToolUse(entry)
                    ? working(since: modified, now: now)
                    : resolveIdle(boundary: boundary, modified: modified, now: now)
            case "user":
                // Either a real prompt (the agent owes an answer) or a tool
                // result (the agent is mid-loop). Both mean working.
                return working(since: modified, now: now)
            default:
                continue  // system, attachment, summary, ai-title…
            }
        }
        return resolveIdle(boundary: boundary, modified: modified, now: now)
    }

    /// The transcript said "idle". Ask the hooks whether that is a finished
    /// turn or a turn still in flight.
    private static func resolveIdle(
        boundary: TurnBoundary?, modified: Date?, now: Date
    ) -> SessionActivity {
        guard let boundary, boundary.kind == .userPromptSubmit else { return .idle }
        // Warmth from whichever source spoke last: the hook row is written at
        // submit and never touched again, so a long turn's only fresh evidence
        // is the transcript's own mtime.
        let warmest = [modified, boundary.at].compactMap { $0 }.max()
        return working(since: warmest, now: now)
    }

    /// `working` only while the evidence is still warm — see `freshness`.
    private static func working(since modified: Date?, now: Date) -> SessionActivity {
        guard let modified, now.timeIntervalSince(modified) <= freshness else { return .idle }
        return .working
    }

    private static func hasToolUse(_ entry: [String: Any]) -> Bool {
        guard let message = entry["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { ($0["type"] as? String) == "tool_use" }
    }

    private static func text(of entry: [String: Any]) -> String {
        guard let message = entry["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let first = content.first, let text = first["text"] as? String
        else { return "stopped on an error" }
        return text
    }

    /// The last `tailBytes` of the file, split into whole lines. The first
    /// line of the window is dropped: seeking to a byte offset lands
    /// mid-record, and half a JSON object is not a record.
    static func tail(of path: String) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let window = String(data: data, encoding: .utf8) else { return nil }
        var lines = window.split(separator: "\n").map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}

extension SessionActivity {
    /// The short reason a blocked row shows, in the row's own width: the
    /// first clause of the error, without the instructions that follow it.
    public var shortReason: String? {
        guard case .blocked(let reason) = self else { return nil }
        let firstSentence = reason.split(separator: ".").first.map(String.init) ?? reason
        return firstSentence
            .replacingOccurrences(of: "You've ", with: "")
            .replacingOccurrences(of: "API Error: ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
