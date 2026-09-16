import CryptoKit
import Foundation

/// Turns an observed change in a remote agent into one line in the spool the
/// hooks already write to.
///
/// **This is the trick that makes the whole feature cheap.** The spool is
/// already the ingestion point for local hook events, and every local-only
/// field on `SpoolRecord` (`cwd`, `transcriptPath`, `tty`) is optional. So a
/// remote change written as a spool line flows through the existing pipeline
/// and arrives as a stored event, a brief, a summary, speech, a hub page and
/// the returned earcon, with **nothing new written** anywhere downstream.
///
/// The alternative was a second pipeline beside the first, which is the drift
/// this whole design exists to avoid: two routes to one answer is how they
/// start disagreeing.
///
/// The consequence, accepted on 12 Sep: the local event table gains rows for
/// work that never ran on this Mac. That is the price of one pipeline and it
/// is the right price.
public enum RemoteSpool {

    /// One line per event, or none.
    ///
    /// Returns the records rather than writing them, so the decision and the
    /// side effect are separable and the decision is testable without a
    /// filesystem. The same shape `GridAssembler.rows` returns its writes in.
    public static func lines(for event: AgentEvent,
                             agent: AgentSession?) -> [SpoolLine] {
        switch event.kind {
        case .said(let turn):
            // Only the agent's own words become a turn. A user message echoed
            // back is already in the log by the route that sent it, and
            // storing it again would announce the user's own sentence to them.
            guard turn.role == .agent, !turn.text.isEmpty else { return [] }
            // Keyed by the TURN, not the moment: the same message seen twice
            // (streamed as it ended, then adopted at the next launch from the
            // server's store) is one turn, and the drainer's dedupe needs the
            // same id both times.
            return [SpoolLine(kind: .stop, event: event, text: turn.text, agent: agent, key: turn.id)]

        case .asks(let request):
            // A question is a TURN, not a Notification. Locally a permission
            // prompt is a Notification because the answer is typed into the
            // pane: the row goes amber with the reason and the tap opens the
            // terminal. A remote agent's answer goes through this app, by
            // voice, so the question has to be what the announcer reads, what
            // the returned earcon fires on, what the row's unread state is,
            // and what the reply target points at. `waitingSessions` counts a
            // session only when its LATEST event is a Stop; as a Notification
            // the question was in none of those (Robert, 15 Sep 5:20 PM: a
            // green row nobody spoke, and the tap opened a Terminal). The
            // matcher still says why, for the hover and the brief.
            return [SpoolLine(kind: .stop, event: event,
                              text: Self.question(request), agent: agent,
                              matcher: "agent_question")]

        case .changed(let session) where session.state.isFinished
            && event.previously?.isFinished != true:
            // A TURN THAT ENDED HAS TO BE WRITTEN, and this is the part that is
            // easy to miss: the green lamp comes from an undismissed stop event
            // in the local database, not from the provider's verdict. Without a
            // line here a finished remote agent has nothing for the grid to
            // find, and the row never goes green no matter how correct the
            // provider's state is.
            let words = session.state == .failed
                ? "The agent stopped: \(session.state.rawValue)."
                : ""
            return [SpoolLine(kind: .stop, event: event, text: words, agent: session)]

        case .failed(let reason):
            // Carries its reason (ruling, 11 Sep). App and provider words only,
            // never the user's own speech.
            return [SpoolLine(kind: .stop, event: event,
                              text: "The agent failed: \(reason)", agent: agent)]

        case .changed:
            // A state change that is not an ending is not news either: the row
            // already shows it from the poller's snapshot, and a spool line
            // would speak every transition from working to idle out loud.
            //
            // Nor is a change while ALREADY finished: a title arriving, a list
            // re-read. Only the transition into finished is a turn ending, and
            // `AgentEvent.previously` is how that is told apart. Robert's
            // first OpenCode turn (15 Sep) was announced as "finished a turn"
            // because the title update that followed the words wrote a bare
            // stop line after them, and the announcer reads the latest.
            return []

        case .appeared, .answered:
            // An agent existing is not news, and an answered question is the
            // absence of news. Writing either would move the read-state
            // watermark past content nobody has seen.
            return []
        }
    }

    /// **A question that died with the process.** The ask lives in the
    /// agent's child process; a relaunch kills the child, and OpenCode marks
    /// the turn interrupted. The next launch adopts the session as finished
    /// (green) with no request, while this app's last word on it is still the
    /// question: the row reads as done, the tap opens the door, and the person
    /// waits on an answer nobody will ask for again (Robert, 15 Sep 8:26 PM:
    /// "same issue with this one, seems stuck, no questions, green lamp").
    /// So when an agent appears with no request and the store's latest turn
    /// for it is an unanswered question, the truth is written as a turn.
    public static func expiredQuestion(for event: AgentEvent, agent: AgentSession?,
                                       latest: WaitingSession?) -> [SpoolLine] {
        guard case .appeared = event.kind,
              let latest, latest.notificationMatcher == "agent_question"
        else { return [] }
        var stamped = event
        stamped.at = max(event.at, Date(timeIntervalSince1970: Double(latest.createdAtMs) / 1000 + 1))
        return [SpoolLine(kind: .stop, event: stamped,
                          text: "The permission it was waiting on expired when the app restarted, "
                              + "and that turn was interrupted. Say what to do next and it will continue.",
                          agent: agent, matcher: "agent_question_expired")]
    }

    /// The question as a turn's words: what it asks and what the choices
    /// are, so the brief has something to recap and the person hears the
    /// options before answering.
    static func question(_ request: PendingRequest) -> String {
        let asked = request.asked.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = request.questions.first?.options.map(\.label).filter { !$0.isEmpty } ?? []
        let choices = options.isEmpty ? "" : " Options: " + options.joined(separator: ", ") + "."
        return "The agent is asking permission: \(asked).\(choices)"
    }

    /// The brief for a question, built from the words `question(_:)` wrote,
    /// without a model: the ask is the recap, the choices are the proposal.
    public static func decision(from words: String, projectLabel: String) -> SessionBrief {
        var asked = words
        var choices: String?
        if let range = words.range(of: " Options: ") {
            asked = String(words[..<range.lowerBound])
            choices = String(words[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        let proposal = choices.map { "\($0). Which?" } ?? "Allow, or reject?"
        return SessionBrief(topic: "Permission", happened: asked, question: proposal,
                            recap: asked, proposal: proposal)
    }

    /// One spool line, in the wire shape `SpoolDrainer` already decodes.
    public struct SpoolLine: Sendable, Equatable {
        public var id: String
        public var createdAtMs: Int64
        public var hookEvent: HookEventKind
        public var sessionId: String
        public var cwd: String?
        public var lastAssistantMessage: String?
        public var notificationMatcher: String?

        init(kind: HookEventKind, event: AgentEvent, text: String,
             agent: AgentSession?, matcher: String? = nil, key: String? = nil) {
            // DETERMINISTIC, not a fresh UUID. The drainer dedupes on the
            // record id, so a poller that sees the same change twice (a retry,
            // a restart, an overlapping tick) must produce the same id or the
            // agent says everything twice. `AgentPoll`'s digest already makes
            // re-emission rare; this makes a duplicate harmless.
            self.id = Self.stableID(event: event, kind: kind, text: text, key: key)
            self.createdAtMs = Int64(event.at.timeIntervalSince1970 * 1000)
            self.hookEvent = kind
            self.sessionId = event.session
            // The REPOSITORY stands in for a working directory, because
            // `QueuedEvent.projectLabel` reads the last path component of `cwd`
            // and that label is what a row and a spoken line call this agent.
            // A remote agent has no directory on this Mac; it does have a
            // repository, and "importer" is a better name than eight hex
            // characters. Nil for a provider with no repository, which
            // projectLabel already handles by falling back to the id.
            // A real directory when the agent has one on this Mac (an ACP
            // child's cwd): the summary request and the branch lookup read it.
            self.cwd = agent?.directory ?? agent?.repository
            self.lastAssistantMessage = text.isEmpty ? nil : text
            self.notificationMatcher = matcher
        }

        static func stableID(event: AgentEvent, kind: HookEventKind, text: String,
                             key: String? = nil) -> String {
            let seed = "\(event.provider)\u{0}\(event.session)\u{0}\(kind.rawValue)"
                + "\u{0}\(key ?? String(Int64(event.at.timeIntervalSince1970 * 1000)))\u{0}\(text)"
            return SHA256.hash(data: Data(seed.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }

        /// The JSON the hook writes, so one decoder serves both writers.
        public func json() -> [String: Any] {
            var line: [String: Any] = [
                "id": id,
                "createdAtMs": createdAtMs,
                "hookEvent": hookEvent.rawValue,
                "sessionId": sessionId,
            ]
            if let cwd { line["cwd"] = cwd }
            if let lastAssistantMessage { line["lastAssistantMessage"] = lastAssistantMessage }
            if let notificationMatcher { line["notificationMatcher"] = notificationMatcher }
            // transcriptPath and tty are deliberately ABSENT rather than empty.
            // Both are local facts a remote agent does not have, both are
            // optional on the record, and an empty string would be read as a
            // path that failed rather than a path that does not exist.
            return line
        }
    }

    /// Append lines to the spool the hooks share.
    ///
    /// The same file, deliberately. A second file would need a second drainer,
    /// a second dedupe and a second truncation rule, and the three would agree
    /// until the day they did not.
    @discardableResult
    public static func append(_ lines: [SpoolLine],
                              to url: URL) -> Int {
        guard !lines.isEmpty else { return 0 }
        var blob = Data()
        for line in lines {
            guard let data = try? JSONSerialization.data(withJSONObject: line.json()) else {
                continue
            }
            blob.append(data)
            blob.append(0x0A)
        }
        guard !blob.isEmpty else { return 0 }
        try? PrivateStorage.createDirectory(at: url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        // APPEND, never read-modify-write. The hook appends to this file from
        // inside a live turn and cannot take a lock; a writer that rewrote the
        // whole file would lose whatever landed in between.
        guard let handle = try? FileHandle(forWritingTo: url) else { return 0 }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: blob)
        return lines.count
    }
}
