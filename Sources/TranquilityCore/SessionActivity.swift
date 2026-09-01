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
    /// The agent stopped on an error it cannot get past on its own. A FACT
    /// read from the file — the transcript says so in as many words.
    case blocked(reason: String)
    /// The file implies a turn is open and nothing has been written to it for
    /// `stalled`. An INFERENCE from silence, and split out of `blocked` on
    /// 18 Aug because the two must not be believed equally.
    ///
    /// Measured that evening on three amber rows Robert called wrong: two of
    /// them (`59181c6d`, `b18ebb61`) had a real typed prompt as their last
    /// conversational entry and nothing after it for four hours — so the file
    /// says "stalled" and means it — while the PROCESS reported `idle` for
    /// both. The prompt was sitting unsent in the composer; Claude Code had
    /// already written it. The file cannot see that and the process can.
    ///
    /// So an error stands on its own evidence and this does not: a stall is
    /// the absence of writing, and "is this agent actually doing anything" is
    /// the one question the process answers better than the transcript. See
    /// the lamp mapping, which lets `idle` and `busy` overrule this and never
    /// overrule `blocked`.
    case stalled(reason: String)
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

    /// How long a live session may say nothing at all before the lamp asks for
    /// a human. RULED 18 Aug, and it replaces a timer that did the opposite.
    ///
    /// The old rule decayed `working` to idle after 15 minutes, which turned
    /// the lamp OFF on a session that was provably running — the panel's live
    /// bands are built from the process list, so a dead session never reaches
    /// this code at all (it is drawn `.unlit` by a different band). That timer
    /// was written 06 Aug, when the panel could not see processes and a clock
    /// was the only defence against a lamp stuck blue forever; liveness landed
    /// 11 Aug and answered the same question with an observation. Nobody
    /// removed the clock, and on 18 Aug it hid a session that had been blocked
    /// on Robert for 41 minutes.
    ///
    /// **The system never turns a lamp off. Only the user does.** A lamp may
    /// be turned UP — toward the user — and that is what this is: an hour of
    /// silence from a live agent is not "never mind", it is "come and look".
    /// Blue past an hour is either working or stuck, and the panel cannot tell
    /// which from a file that stopped changing; amber says so honestly and
    /// puts the row in front of you instead of retiring it.
    public static let stalled: TimeInterval = 60 * 60

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
    /// The stall escalation applies either way: a prompt with no Stop after it
    /// holds a lamp blue, and once an hour has passed with nothing written it
    /// turns amber rather than quietly going out.
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

            // Codex, asked in its own language. `CodexRollout.record` is the
            // only thing in this repo that knows what a rollout line looks
            // like — it decodes `task_complete`, `turn_aborted` and the rest,
            // and unwraps the API bodies some errors arrive wrapped in.
            //
            // This block used to be a second hand-rolled walk over the same
            // JSON, written here because this is where the lamp lived. It had
            // already fallen behind the real parser: no `turn_aborted`, of
            // which there are 30 on this machine, so an Esc'd turn read as
            // working — the same shape as the fourteen-hour blue lamp it was
            // written to fix. Robert, 01 Sep: "is our architecture defensible,
            // simple, and can we extend it to other errors in the future?"
            //
            // The division that answers that: the ADAPTER's format knows what
            // was said, and this function decides what it means. Everything
            // below — precedence, staleness, the transient grace — is the same
            // for every harness, and none of it needs to know about JSON.
            switch CodexRollout.record(line) {
            case .turnEnded(let turn):
                // Rule 1 of the precedence note above, reached by a harness
                // that had no way to state it. No transient grace: this record
                // IS the turn ending, so no retry is coming that could move
                // the tail past it.
                if let error = turn.error {
                    return (.blocked(reason: error), observed)
                }
                // Completed, or aborted by the user. Either way the turn is
                // over — Codex's own `turn_duration`, which is what a Stop
                // hook that never fires leaves nobody to say.
                endedAt = endedAt ?? observed
                if turnIsOver(endedAt: endedAt, boundary: boundary) {
                    return (.idle, observed)
                }
                continue
            case .turnStarted:
                // Working, said by the harness rather than inferred from a
                // hook. `working` still decides from its age whether that is
                // still true.
                return (working(since: observed, now: now), observed)
            case .content, .activity:
                // Somebody wrote something, or the agent ran a tool. Both are
                // movement at this timestamp — the same meaning as an
                // assistant entry with a tool use in Claude Code's file — and
                // `working` decides from its age whether it is still true.
                return (working(since: observed, now: now), observed)
            case .meta, .ignored, .undecodable:
                break   // not a Codex line, or nothing this decides on
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

    /// Blue while the agent is moving; amber once it has been silent long
    /// enough that a human should look — see `stalled`. Never off: nothing
    /// here can produce `.idle` from the passage of time alone.
    ///
    /// `observed` is the timestamp of the transcript ENTRY the verdict was read
    /// from, not the file's mtime. They are not the same clock, and dating the
    /// verdict by the file was the bug: Claude Code keeps writing to a finished
    /// session's transcript — `file-history-snapshot` updates, `ai-title`,
    /// `bridge-session`, `pr-link`, `mode` — none of which is the conversation
    /// saying anything. Each such write re-armed the stale-verdict clock, so an
    /// hours-old "working" verdict was certified fresh over and over and the
    /// lamp never decayed. Measured 18 Aug across the 30 most recent
    /// transcripts: 19 carried an mtime newer than their last conversational
    /// entry, by a median of 98 minutes and a maximum of four days; two of the
    /// three blue lamps on the grid at 17:19 were sessions that had finished
    /// 105 and 149 minutes earlier. The gate was never broken — it
    /// was being fed the wrong clock.
    private static func working(since observed: Date?, now: Date) -> SessionActivity {
        // No dated evidence at all is not silence, it is an unreadable file.
        // Say idle rather than invent an age for it.
        guard let observed else { return .idle }
        let silence = now.timeIntervalSince(observed)
        guard silence > stalled else { return .working }
        return .stalled(reason: "silent for \(spoken(silence)), nothing written since it started this")
    }

    /// A duration a row can carry in its reason column, in the units a person
    /// would say: "1h", "3h", "2d".
    static func spoken(_ seconds: TimeInterval) -> String {
        if seconds < 5400 { return "\(Int(seconds / 60))m" }
        if seconds < 172_800 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// When this agent last moved, as a column can say it: "22m ago", "5h ago",
    /// "Aug 15".
    ///
    /// The Past Agents list is a SEARCH surface — "there is a workstream I did a
    /// week ago and I don't know which tab it is in" — and the question it has
    /// to answer first is *when*. So the column carries this instead of the
    /// short id (ruled 19 Aug); the id moves to the tooltip, where it is still a
    /// click away and no longer costs the name its width.
    ///
    /// Relative under two days, absolute beyond it, and the cutoff is the whole
    /// point rather than a tuning knob. "3d" is a duration a reader has to do
    /// arithmetic on to place, and they will do it against the wrong anchor;
    /// past about two days a person navigates by date, not by elapsed time, and
    /// says "the Tuesday one". Under two days the reverse holds — "Aug 19" for
    /// something that happened this morning is strictly less information than
    /// "5h ago", because it drops the hours the reader still has in their head.
    ///
    /// Feed this `Session.lastActivityAt`, which since 19 Aug means the newest
    /// timestamp the CONVERSATION wrote. It must never be fed a file's mtime:
    /// Claude Code appends untimestamped bookkeeping whenever a session is
    /// merely opened or resumed, so an mtime-dated column would rank Robert's
    /// browse order and tell him a session idle since breakfast had just moved.
    /// Two features have now been cured of exactly that (the lamp on 18 Aug,
    /// the closed-band ranking on 19 Aug); this is the third reader of the same
    /// clock and it inherits the cure rather than re-earning the bug.
    public static func lastMovedLabel(_ moved: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(moved)
        // A clock that has run backwards (a transcript stamped in the future,
        // an NTP step mid-scan) is not "in 3 minutes" — say the thing that is
        // true and unsurprising rather than inventing a tense for it.
        guard elapsed > 0 else { return "now" }
        if elapsed < 60 { return "now" }
        if elapsed < 172_800 { return "\(spoken(elapsed)) ago" }
        return absoluteDay.string(from: moved)
    }

    /// Built once. `DateFormatter` costs milliseconds to construct and this is
    /// called per row, per opening of a list that can hold the whole archive.
    /// Fixed to POSIX so the drill asserting "Aug 15" is not a claim about
    /// whichever locale the test machine happens to carry.
    private static let absoluteDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

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
    /// The whole sentence, for the tooltip.  is cut to a row's
    /// width and the row truncates what is left of it again, so on 18 Aug the
    /// only place an error or a stall could be READ was the log — Robert:
    /// "there's no way to see the full message, the full error." This is the
    /// text the hover shows, uncut.
    public var fullReason: String? {
        switch self {
        case .blocked(let r), .stalled(let r): return r
        case .working, .idle: return nil
        }
    }

    public var shortReason: String? {
        let reason: String
        switch self {
        case .blocked(let r), .stalled(let r): reason = r
        case .working, .idle: return nil
        }
        // ". " and not ".", because a bare period is not a sentence boundary
        // in the strings this actually receives. Codex's first error to reach
        // this row was `stream disconnected before completion: error sending
        // request for url (https://api.openai.com/v1/responses)`, and cutting
        // at the first period left the row reading "...url (https://api".
        let firstSentence = reason.components(separatedBy: ". ").first ?? reason
        let stripped = firstSentence
            .replacingOccurrences(of: "You've ", with: "")
            .replacingOccurrences(of: "API Error: ", with: "")
            .trimmingCharacters(in: .whitespaces)
        // A long "<what went wrong>: <where>" keeps the half that says what
        // went wrong. The row has one line and the first clause is the half a
        // person reads; the rest is still one hover away in `fullReason`.
        // Only when it is long enough to be truncated anyway, and only when
        // the label that survives is worth having — so "429 rate limit
        // exceeded" is left exactly as it is.
        guard stripped.count > 60,
              let colon = stripped.range(of: ": "),
              stripped.distance(from: stripped.startIndex, to: colon.lowerBound) >= 12
        else { return stripped }
        return String(stripped[stripped.startIndex..<colon.lowerBound])
    }
}
