import Foundation

// MARK: - Contract

public struct SummaryRequest: Sendable {
    public var lastAssistantMessage: String
    public var projectLabel: String
    /// The session's opening ask. Without it the brief has no subject — which is
    /// exactly what made the first version unusable across ten parallel sessions.
    public var firstUserMessage: String?
    public var gitBranch: String?
    public var cwd: String?
    public var hookEvent: HookEventKind
    public var notificationMatcher: String?
    /// Appended to the user message on a digit-grounding retry (open issue #9):
    /// names the ungrounded number(s) so the model can remove or correct them.
    /// Never set on a first attempt.
    public var correctiveNote: String?

    public init(
        lastAssistantMessage: String,
        projectLabel: String,
        firstUserMessage: String? = nil,
        gitBranch: String? = nil,
        cwd: String? = nil,
        hookEvent: HookEventKind = .stop,
        notificationMatcher: String? = nil,
        correctiveNote: String? = nil
    ) {
        self.lastAssistantMessage = lastAssistantMessage
        self.projectLabel = projectLabel
        self.firstUserMessage = firstUserMessage
        self.gitBranch = gitBranch
        self.cwd = cwd
        self.hookEvent = hookEvent
        self.notificationMatcher = notificationMatcher
        self.correctiveNote = correctiveNote
    }
}

public struct Summary: Sendable {
    public let spoken: SanitizedSpokenText
    public let brief: SessionBrief
    public let provider: String
    public let latencyMs: Int
}

public protocol SummaryProvider: Sendable {
    var name: String { get }
    var isConfigured: Bool { get }
    func brief(for request: SummaryRequest) async throws -> SessionBrief
}

public enum SummaryError: Error, Sendable {
    case notConfigured
    case http(Int, String)
    case emptyResponse
    case unparseable(String)
}

// MARK: - The floor
//
// Never fails, never calls anything. If every other provider is down the loop still
// says something true rather than going silent — but it is a floor, not a product.

public struct DeterministicSummarizer: SummaryProvider {
    public let name = "deterministic"
    public let isConfigured = true
    public init() {}

    public func brief(for request: SummaryRequest) async throws -> SessionBrief {
        if request.hookEvent == .notification {
            return SessionBrief(
                topic: request.projectLabel,
                happened: Self.notificationLine(request),
                question: "Does it have your go-ahead?")
        }
        let happened = Self.firstSentences(
            of: request.lastAssistantMessage.replacingOccurrences(of: "\n", with: " "), count: 2)
        return SessionBrief(
            topic: request.projectLabel,
            happened: happened.isEmpty ? "finished a turn" : happened,
            branch: request.gitBranch)
    }

    /// Split on sentence-ending punctuation followed by whitespace — never on a bare
    /// `.`, which would cut `format.swift` and `3.14` in half and leave debris the
    /// sanitizer can no longer recognise as a filename.
    static func firstSentences(of text: String, count: Int) -> String {
        let pattern = try? NSRegularExpression(pattern: "(?<=[.!?])\\s+")
        let full = NSRange(text.startIndex..., in: text)
        var pieces: [String] = []
        var cursor = text.startIndex

        pattern?.enumerateMatches(in: text, range: full) { match, _, stop in
            guard let match, let range = Range(match.range, in: text) else { return }
            pieces.append(String(text[cursor..<range.lowerBound]))
            cursor = range.upperBound
            if pieces.count >= count { stop.pointee = true }
        }
        if pieces.count < count, cursor < text.endIndex {
            pieces.append(String(text[cursor...]))
        }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func notificationLine(_ request: SummaryRequest) -> String {
        switch request.notificationMatcher {

        case "permission_prompt": return "waiting for permission to continue"
        case "idle_prompt": return "idle and waiting on you"
        case "agent_needs_input": return "needs input before it can carry on"
        default: return "needs your attention"
        }
    }
}

// MARK: - Anthropic

/// Fills the brief's fields rather than writing free prose.
///
/// Free prose produced true-but-unusable fragments: "the fix has never run in the
/// deployed pipeline" names no subject and proposes no action, which is worthless
/// when ten sessions are in flight. Fields force the model to answer the questions
/// that actually matter, and the spoken line is then assembled in priority order.
///
/// This is a plain API call rather than a `claude -p` subprocess: a subprocess would
/// load global CLAUDE.md, memory, skills, MCP servers and every SessionStart hook to
/// write thirty words, then fire its own Stop hook.
public struct AnthropicSummaryProvider: SummaryProvider {
    public let name = "anthropic"
    public var model: String
    public var timeout: TimeInterval

    public init(model: String = "claude-haiku-4-5-20251001", timeout: TimeInterval = 20) {
        self.model = model
        self.timeout = timeout
    }

    public var isConfigured: Bool { Secrets.has(.anthropicAPIKey) }

    // The tuned prompt, ported verbatim from tools/replay/prompts/vnext-a.txt
    // (three replay rounds plus a 50-record generalization pass against real
    // history). The pre-tuning baseline is preserved at
    // tools/replay/prompts/current.txt — every wording difference between the two
    // is a measured decision, not style.
    //
    // The template's slots map to the user message built in `brief(for:)`:
    // {project_label} {notification_block} {branch_block} {opening_block}
    // {last_assistant_message} correspond one-to-one to the string interpolations
    // there; the system prompt is everything above the "Project:" line. The one
    // slot the system prompt itself uses — {project_label} in the recap rule — is
    // substituted here, exactly as the replay harness rendered it.
    static func systemPrompt(projectLabel: String) -> String { """
        You are the dispatcher for a developer running many coding-agent sessions at \
        once. One just finished a turn. You write the ONE spoken update they will hear \
        about it, in loop discipline: callsign first, short, exact, one decision.

        Reply with ONLY a JSON object, no prose and no code fence:

        {
          "recap":    "spoken part one: callsign + what concluded, 12 words max",
          "proposal": "spoken part two: proposed next action + the question, under 15 words",
          "rationale": "spoken on the WHY pull: why this proposal, about 30 words, or null",
          "findings": "spoken on the FINDINGS pull: what the work TURNED UP, about 30 words, or null",
          "solution": "spoken on the SOLUTION pull: the concrete shape of what is proposed, about 30 words, or null",
          "topic":    "3-6 words naming this work, for a list",
          "goal":     "what this session is trying to achieve, or null",
          "happened": "what just concluded, one clause",
          "nextStep": "the proposed next action, or null",
          "question": "the decision being put to the user, or null",
          "risk":     "a risk worth knowing before deciding, or null"
        }


        ── "recap": 12 words max, one sentence ──

        - The user stepped away and is coming back; they'll hear only this. Lead with \
        the one thing that changed.
        — skip root-cause narrative, fix internals, and secondary to-dos.
        - MUST open with the project label spoken verbatim: "\(projectLabel):" the \
        listener is tracking many sessions; the name is how they know which one this is.
        - Then what concluded, with its exact parameters. Numbers and specifics beat \
        adjectives: "three alerts posted", not "some alerts".
        - NEVER speak a number that is not in the source message. If the source has no \
        number, use none.

        ── "proposal": under 15 words ──

        The user answers without opening the tab. "Yes" must be a complete and safe reply:
        - The proposed action, specific and parameterized, taken ONLY from the agent's \
        final message.
        - ONE action per proposal. If the source offers alternatives, name the agent's \
        preferred one and ask. Never invent durations, thresholds, or schedules ("for \
        twenty-four hours") the source does not state.
        - End with the decision as a question answerable in one word: "Go?", \
        "Proceed?", "Ship it?"
        - EXCEPTION of closed-out work: only when the source proposes nothing, asks \
        nothing, and does not end on a discussion point may you state the closure \
        plainly with NO question and set "question" to null. "Shipped and tests green" \
        is not enough; if the message ends on an observation, an open thread, or \
        anything inviting a reaction, the thread is alive: ask. When in doubt, ask.
        - If the action is destructive or hard to reverse (deletes, force-pushes, \
        sends to real people, spends money), the risk MUST be spoken in this section, \
        compressed to a clause. For ordinary actions, the risk lives in the "risk" \
        field, not in the spoken text; the user can pull it on demand.

        ── "rationale": 40 words MAX, spoken ONLY when the user asks for more ──

        The user heard the recap and proposal and pressed for depth. Answer "why?":
        - The shape is literally: "We propose X because Y. We need to be careful \
        about Z."
        - Y is the reason for THIS action now, taken from the agent's final message: \
        what it found, what it tried, what constraint forces the choice.
        - Z is the main risk and its blast radius — what actually breaks if it goes \
        wrong. If there is no real risk, skip Z rather than hedging.
        - About 30 words; never more than 40 — anything past that is cut mid-thought \
        at a sentence boundary, so say less and land it. Spend the words on Y and Z; \
        leftover state only if room remains.
        - ALWAYS open with "We propose" — the shape is the contract, not a suggestion.
        - Name X concretely. "We propose addressing this" is a failure: the listener \
        cannot resolve "this", and the rationale must stand alone. The action and its \
        object are named IN THIS FIELD — never a pronoun whose referent lives in the \
        recap, the proposal, or the source message.
        - Flowing speech, dense but plain. No lists, no labels, no headings. \
        Speakability applies with full force: no paths, no symbols, no hashes — this \
        is speech.
        - Every sentence must add a fact the recap and proposal did not carry. \
        Repeating them is the failure mode this field exists to fix.
        - null only when the turn is trivial and closed, with nothing behind it.

        ── "findings": 40 words MAX, spoken only on request ──

        What the work TURNED UP, not what was done: results, numbers, discoveries, \
        surprises, failures. "Recovered three misfiled pieces; the scanner missed \
        one class entirely" is findings; "audited the directory" is not. Dense, \
        plain, and speakable — no paths, no symbols, no URLs. null when the turn \
        genuinely produced no findings — a pure plumbing turn has none, and \
        inventing some is the worst failure available.

        ── "solution": 40 words MAX, spoken only on request ──

        The concrete shape of the proposed work: the pieces, their order, what \
        each does. If the source ranks items (P1..P7), speak the count and the top \
        items: "Seven fixes ranked; the top three: X, then Y, then Z." Name real \
        things the source names — products and projects, never paths, symbols, or \
        URLs; describe a link as where it leads. null when nothing is proposed.

        ── ALL FIVE SPOKEN FIELDS (recap, proposal, rationale, findings, solution) ──

        Spoken, not displayed. Never speak file paths, branch names, function or \
        variable names, hashes, or UUIDs; describe them ("the asset pool"). Product \
        names, project names, service names, and ordinary proper nouns ARE speakable; \
        say "Klaviyo", not "an email platform"; vague paraphrase of a known name is \
        worse than the name.

        Write every one of them as words, the way you would say them: numbers spelled \
        out as separate words ("twenty-two ninety-four" for 2294, never one hyphenated \
        run; "four and a half hours"; "a four oh one"), and the common word wherever \
        one exists. Assume the listener hears this once, in their second language.

        ── THE REMAINING FIELDS ──

        Card fields: displayed in lists and cards, NEVER spoken. 12 words or fewer \
        each; these MAY name symbols and paths precisely because they are read, not \
        heard. Use null when a field genuinely does not apply. Never invent a \
        question or a risk.

        ── GROUNDING: overrides everything above ──

        Every fact, and especially the proposed next step, must come from the agent's \
        final message. If that message does not say what comes next, say what it says \
        happened and stop; do not invent a plausible next task, and never take one \
        from how the session opened. Naming work the session is not doing is the \
        worst failure available to you.

        Attribution: the work was done by the agent, not the user. "The session \
        validated…", never "you validated…". Reserve "you" for what the user asked \
        for and must decide.

        There is always a decision when a next step exists: whether to let the agent \
        proceed or redirect it. Never say "no input is needed"; for a session with a \
        next step, that sentence is false; the thread will not continue without a reply.

        ── EXAMPLES (loop discipline: real shape, invented content) ──

        Source says: poller deployed, three alerts posted to Slack, proposes adding a \
        Shopify-only filter.
        {"recap": "Promotions: poller live, three alerts posted.", "proposal": "Add \
        the Shopify-only filter next. Go?", "rationale": "We propose the filter \
        because two thirds of alert volume is non-Shopify noise the team ignores; \
        all three real breaches today were Shopify orders. We need to be careful \
        about over-filtering, which would hide a breach until the daily digest.", ...}

        Source says: migration script ready, will DROP the legacy table when run.
        {"recap": "Kopi: migration script ready.", "proposal": "Running it drops the \
        legacy table. Irreversible. Run it?", "rationale": "We propose running it \
        because eleven thousand rows verified clean on staging, and the legacy table \
        blocks the new queue schema. We need to be careful: the only rollback is the \
        nightly backup, restored successfully this morning as a rehearsal.", ...}

        """ }

    public func brief(for request: SummaryRequest) async throws -> SessionBrief {
        guard let key = Secrets.read(.anthropicAPIKey) else { throw SummaryError.notConfigured }

        // Notifications used to short-circuit to the deterministic line on the
        // grounds that a model adds nothing to "it wants permission". That was true
        // when a notification carried no content. It now carries the transcript's
        // last assistant message, and for a plan-approval prompt that message IS the
        // plan — so "waiting for permission to continue" throws away the only thing
        // worth saying. Fall back only when there is genuinely nothing to read.
        if request.hookEvent == .notification, request.lastAssistantMessage.isEmpty {
            return try await DeterministicSummarizer().brief(for: request)
        }

        var context = "Project: \(request.projectLabel)"
        if request.hookEvent == .notification {
            context += """


                THIS SESSION IS BLOCKED AND WAITING ON THE USER \
                (\(request.notificationMatcher ?? "needs input")). The message below \
                is what it is asking about. Say what it wants to do and what the \
                decision is — approving a plan is a decision, and reading out \
                "waiting for permission" tells them nothing they did not already know.
                """
        }
        if let branch = request.gitBranch { context += "\nBranch: \(branch)" }
        if let ask = request.firstUserMessage {
            // Background only, and explicitly stale. A long session drifts far from
            // how it opened, and without this the model narrates the original brief
            // — describing a Kanban viewer hours after that idea was abandoned.
            context += """


                How this session opened, HOURS AGO and possibly abandoned since. \
                Use it only to disambiguate names. Never describe it as current \
                work, and never propose a next step from it:
                \(ask)
                """
        }

        var user = """
            \(context)

            The agent's final message this turn:
            \(request.lastAssistantMessage)
            """
        if let note = request.correctiveNote {
            user += "\n\n\(note)"
        }

        let system = Self.systemPrompt(projectLabel: request.projectLabel)
        let body: [String: Any] = [
            "model": model,
            // Sized for the FIVE-spoken-field brief plus cards with 2x headroom.
            // At 400, the ladder prompt's response truncated mid-JSON
            // (stop_reason max_tokens, the required "happened" cut off), parse
            // failed, and every announcement fell to the deterministic floor —
            // long raw-ish spoken text and an empty ladder (observed 06 Aug,
            // 01:07Z). Truncation costs the whole brief; tokens cost nothing.
            "max_tokens": 1024,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        guard let http = response as? HTTPURLResponse else { throw SummaryError.emptyResponse }

        ModelCallLog.record(
            model: model, status: http.statusCode, elapsedMs: elapsedMs,
            system: system, user: user,
            response: String(data: data, encoding: .utf8) ?? "<undecodable>")
        guard http.statusCode == 200 else {
            throw SummaryError.http(http.statusCode, String(String(data: data, encoding: .utf8)?.prefix(200) ?? ""))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { throw SummaryError.emptyResponse }

        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return try Self.parse(text, request: request)
    }

    static func parse(_ text: String, request: SummaryRequest) throws -> SessionBrief {
        // Tolerate a stray code fence or leading prose.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw SummaryError.unparseable(String(text.prefix(120)))
        }
        let jsonSlice = String(text[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw SummaryError.unparseable(String(jsonSlice.prefix(120))) }

        func field(_ key: String) -> String? {
            guard let raw = obj[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty || trimmed.lowercased() == "null") ? nil : trimmed
        }

        guard let happened = field("happened") else {
            throw SummaryError.unparseable("no happened field")
        }
        return SessionBrief(
            topic: field("topic") ?? request.projectLabel,
            goal: field("goal"),
            happened: happened,
            nextStep: field("nextStep"),
            question: field("question"),
            risk: field("risk"),
            rationale: field("rationale"),
            findings: field("findings"),
            solution: field("solution"),
            branch: request.gitBranch,
            recap: field("recap"),
            proposal: field("proposal"))
    }
}

// MARK: - Chain

/// Tries providers in order and always returns something. A silent loop is a broken
/// loop, so the last provider is the deterministic floor.
public struct SummarizerChain: Sendable {
    public let providers: [any SummaryProvider]
    public let sanitizer = SpokenTextSanitizer()
    /// Pull request lookup is deterministic — the model is never asked whether a PR
    /// exists, because it would guess.

    public init(providers: [any SummaryProvider]? = nil) {
        self.providers = providers ?? [AnthropicSummaryProvider(), DeterministicSummarizer()]
    }

    /// Set by the app so grounding retries and empty-source skips explain themselves.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// `lexicon` (A7) joins the per-message allowlist: names established by
    /// RECENT sessions stay speakable even when this one message did not
    /// capitalize them. Like the per-message set, it can only exempt tokens
    /// from the identifier rules — paths and hashes are stripped regardless.
    public func summarize(_ request: SummaryRequest, lexicon: Set<String> = []) async -> Summary {
        let start = Date()
        var produced: (SessionBrief, String)?

        // An empty final message never reaches a model. The model correctly refuses
        // to summarize nothing, which burns a call to learn what we already know —
        // so the deterministic floor answers directly and the provider name records
        // why. (The event `status` column was dropped in v3, so "summaryFailed" is
        // no longer a writable state; this tag plus the trace line is the closest
        // surviving failure path.)
        let emptySource = request.lastAssistantMessage
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if emptySource {
            SummarizerChain.trace?(
                "summarize: empty source for \(request.projectLabel); model not called")
            if let floor = try? await DeterministicSummarizer().brief(for: request) {
                produced = (floor, "empty-source")
            }
        } else {
            for provider in providers where provider.isConfigured {
                if let brief = try? await provider.brief(for: request) {
                    let grounded = await groundDigits(brief, request: request, provider: provider)
                    produced = (grounded.brief,
                                provider.name + (grounded.scrubbed ? "+digit-scrubbed" : ""))
                    break
                }
            }
        }
        if produced == nil,
           let fallback = try? await DeterministicSummarizer().brief(for: request) {
            produced = (fallback, "deterministic-fallback")
        }

        var (brief, providerName) = produced
            ?? (SessionBrief(topic: request.projectLabel, happened: "finished a turn"), "none")

        // Names the source itself used are speakable ("say Klaviyo, not 'an email
        // platform'"); everything identifier-shaped is still stripped.
        let speakable = SpokenTextSanitizer.speakableTerms(in: request.lastAssistantMessage)
            .union(lexicon)

        // Each section is clamped against its own budget before composing, so a long
        // recap can never eat the proposal — the half that carries the decision.
        //
        // Clamped but NOT redacted: the brief keeps the names the session itself
        // used, because that is what the card shows and what the store keeps. The
        // genericising happens once, below, and produces a value carrying both
        // forms — so the thing read and the thing heard are two projections of one
        // sequence rather than two strings that have to be kept in step.
        if let recap = brief.recap {
            brief.recap = SpokenTextSanitizer.clamp(
                recap, maxWords: SpokenTextSanitizer.recapWords)
        }
        if let proposal = brief.proposal {
            brief.proposal = SpokenTextSanitizer.clamp(
                proposal, maxWords: SpokenTextSanitizer.proposalWords)
        }

        return Summary(
            spoken: sanitizer.sanitize(brief.spokenText(), allowing: speakable),
            brief: brief,
            provider: providerName,
            latencyMs: Int(Date().timeIntervalSince(start) * 1000))
    }

    /// Digit grounding (open issue #9): a number the source never said must not be
    /// spoken. One corrective retry; if the retry still invents numbers, the
    /// offending clauses are scrubbed rather than spoken — a summary missing a
    /// clause beats a confident wrong number, and this path must never crash.
    private func groundDigits(
        _ brief: SessionBrief, request: SummaryRequest, provider: any SummaryProvider
    ) async -> (brief: SessionBrief, scrubbed: Bool) {
        let pool = DigitGrounding.sourcePool(for: request)
        let offending = DigitGrounding.ungroundedTokens(in: brief, pool: pool)
        guard !offending.isEmpty else { return (brief, false) }

        var retryRequest = request
        retryRequest.correctiveNote =
            "Your previous reply spoke the number(s) \(offending.joined(separator: ", ")) "
            + "not present in the source. Remove or correct them."
        SummarizerChain.trace?(
            "digit grounding: ungrounded \(offending.joined(separator: ",")) "
            + "in \(request.projectLabel); retrying once")

        if let retried = try? await provider.brief(for: retryRequest) {
            let still = DigitGrounding.ungroundedTokens(in: retried, pool: pool)
            guard !still.isEmpty else { return (retried, false) }
            SummarizerChain.trace?(
                "digit grounding: retry still ungrounded (\(still.joined(separator: ","))); "
                + "scrubbing")
            return (DigitGrounding.scrub(retried, tokens: Set(still)), true)
        }
        SummarizerChain.trace?("digit grounding: retry failed; scrubbing first attempt")
        return (DigitGrounding.scrub(brief, tokens: Set(offending)), true)
    }
}
