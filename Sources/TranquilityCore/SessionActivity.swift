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
    public static let freshness: TimeInterval = 15 * 60

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
        evidence(transcriptPath: transcriptPath, boundary: boundary, now: now)?.activity
    }

    /// The verdict WITH the two clocks it was weighed against, so an audit can
    /// ask the question a lamp cannot answer by looking at itself: is this
    /// verdict resting on something the conversation said, or on a file that
    /// merely moved? `tbase lamps` prints the drift between them; a lamp lit by
    /// a file is the failure that shipped on 18 Aug.
    public struct Evidence: Sendable, Equatable {
        public let activity: SessionActivity
        /// Timestamp of the transcript entry the verdict was read from.
        public let observedAt: Date?
        /// The transcript file's own mtime.
        public let modifiedAt: Date?
        /// How far the file's clock has run past the conversation's. Large
        /// drift is normal and harmless; it is only dangerous when something
        /// dates a verdict by the file.
        public var drift: TimeInterval? {
            guard let observedAt, let modifiedAt else { return nil }
            return modifiedAt.timeIntervalSince(observedAt)
        }
    }

    public static func evidence(
        transcriptPath: String, boundary: TurnBoundary? = nil, now: Date = Date()
    ) -> Evidence? {
        guard let tail = tail(of: transcriptPath) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date
        let verdict = self.verdict(tail: tail, modified: modified, boundary: boundary, now: now)
        return Evidence(activity: verdict.activity, observedAt: verdict.observedAt,
                        modifiedAt: modified)
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
        verdict(tail: tail, modified: modified, boundary: boundary, now: now).activity
    }

    /// `classify`, plus the date of the entry the verdict rests on — one walk,
    /// so the audit and the lamp can never disagree about which line decided.
    static func verdict(
        tail: [String], modified: Date?, boundary: TurnBoundary? = nil, now: Date = Date()
    ) -> (activity: SessionActivity, observedAt: Date?) {
        // Walk backwards to the first entry that says anything about the
        // conversation. system/attachment/summary lines are bookkeeping —
        // Claude Code writes several of them AFTER an error, which is why
        // "the last line" is the wrong question to ask.
        //
        // One system line is NOT bookkeeping: `turn_duration`. Claude Code
        // writes it the moment a turn ends, and walking backwards means any
        // one we pass is NEWER than the conversational entry we are about to
        // find — which makes it a first-hand statement that the turn those
        // words belonged to is over. See `endedAt`.
        var endedAt: Date?
        for line in tail.reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let type = entry["type"] as? String
            // The entry's OWN time is the age of the evidence — see
            // `working(since:)`. mtime only stands in when the line carries
            // no timestamp, which real user/assistant entries always do.
            let observed = timestamp(of: entry) ?? modified

            if type == "system", entry["subtype"] as? String == "turn_duration" {
                endedAt = endedAt ?? observed
                continue
            }

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
                    return (.idle, observed)
                }
                return (.blocked(reason: reason), observed)
            }
            switch type {
            case "assistant", "user":
                // The turn these words belonged to has been declared over, and
                // nothing has been submitted since. Whatever the words look
                // like, the agent is not holding them any more.
                if turnIsOver(endedAt: endedAt, boundary: boundary) {
                    return (.idle, observed)
                }
                if type == "user" {
                    // Either a real prompt (the agent owes an answer) or a tool
                    // result (the agent is mid-loop). Both mean working.
                    return (working(since: observed, now: now), observed)
                }
                // A turn that ends in a tool call is still running. One that
                // ends in prose LOOKS finished — but mid-turn prose is the
                // same shape, so that verdict is the ambiguous one and the
                // hooks get the final word on it.
                return (hasToolUse(entry)
                    ? working(since: observed, now: now)
                    : resolveIdle(boundary: boundary, observed: observed, now: now), observed)
            default:
                continue  // system, attachment, summary, ai-title…
            }
        }
        return (resolveIdle(boundary: boundary, observed: modified, now: now), nil)
    }

    /// Whether the transcript has declared the turn over, with the hooks given
    /// the one chance to overrule it that they legitimately have.
    ///
    /// `turn_duration` is written when a turn ends and is followed by the NEXT
    /// prompt or by nothing at all — measured 18 Aug over the 25 most recently
    /// touched transcripts: 59 occurrences, every one of them immediately after
    /// the last message of a turn (57 assistant prose, 1 tool result), and not
    /// once followed by the same turn continuing. So it settles the case the
    /// hooks were introduced for, from inside the file, without depending on a
    /// Stop that fires in only 1 of 10 usage-limit deaths.
    ///
    /// The exception the boundary earns: a prompt SUBMITTED after the turn
    /// ended is a new turn whose first line may not be on disk yet (Claude Code
    /// creates the transcript when the first user message lands, which is the
    /// race #118 fixed on the send path). A `userPromptSubmit` newer than the
    /// marker therefore wins; anything older cannot.
    ///
    /// Absence proves nothing. Older transcripts, and any Claude Code that does
    /// not write the marker, fall through to the rules below exactly as before.
    private static func turnIsOver(endedAt: Date?, boundary: TurnBoundary?) -> Bool {
        guard let endedAt else { return false }
        guard let boundary, boundary.kind == .userPromptSubmit else { return true }
        return boundary.at <= endedAt
    }

    /// The transcript said "idle". Ask the hooks whether that is a finished
    /// turn or a turn still in flight.
    private static func resolveIdle(
        boundary: TurnBoundary?, observed: Date?, now: Date
    ) -> SessionActivity {
        guard let boundary, boundary.kind == .userPromptSubmit else { return .idle }
        // Warmth from whichever source spoke last: the hook row is written at
        // submit and never touched again, so a long turn's fresh evidence is
        // the last thing the CONVERSATION wrote — never the file's mtime,
        // which moves for reasons that are not the conversation at all.
        let warmest = [observed, boundary.at].compactMap { $0 }.max()
        return working(since: warmest, now: now)
    }

    /// `working` only while the evidence is still warm — see `freshness`.
    ///
    /// `observed` is the timestamp of the transcript ENTRY the verdict was read
    /// from, not the file's mtime. They are not the same clock, and dating the
    /// verdict by the file was the bug: Claude Code keeps writing to a finished
    /// session's transcript — `file-history-snapshot` updates, `ai-title`,
    /// `bridge-session`, `pr-link`, `mode` — none of which is the conversation
    /// saying anything. Each such write re-armed the freshness gate, so an
    /// hours-old "working" verdict was certified fresh over and over and the
    /// lamp never decayed. Measured 18 Aug across the 30 most recent
    /// transcripts: 19 carried an mtime newer than their last conversational
    /// entry, by a median of 98 minutes and a maximum of four days; two of the
    /// three blue lamps on the grid at 17:19 were sessions that had finished
    /// 105 and 149 minutes earlier. The freshness gate was never broken — it
    /// was being fed the wrong clock.
    private static func working(since observed: Date?, now: Date) -> SessionActivity {
        guard let observed, now.timeIntervalSince(observed) <= freshness else { return .idle }
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
