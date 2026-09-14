import Foundation

// MARK: - Contract

public struct SummaryRequest: Sendable {
    public var lastAssistantMessage: String
    public var projectLabel: String
    /// The session's opening ask. Without it the brief has no subject — which is
    /// exactly what made the first version unusable across ten parallel sessions.
    public var firstUserMessage: String?
    /// The goal this session was carrying INTO this turn, so the model can
    /// keep it rather than invent a new one.
    ///
    /// Measured 19 Aug, across 59 sessions of 5+ turns averaging 17.1 turns:
    /// the average number of DISTINCT goals was 17.0, and not one session in 59
    /// kept a single goal. The field's own doc said "the goal is the one field
    /// that must not drift with the work" and the hub compensated by reading
    /// the oldest brief's copy and discarding the rest.
    ///
    /// The cause was not sloppiness. Every other field answers "what happened
    /// in THIS turn", which is in the model's input; `goal` asks "what is this
    /// session for", which was not. Given one turn's text it inferred a
    /// plausible aim from that turn and wrote a fresh one, sixteen times in a
    /// row. Carrying the previous value in turns the question into one the
    /// input can answer: keep this, or say what changed.
    public var previousGoal: String?
    public var gitBranch: String?
    public var cwd: String?
    public var hookEvent: HookEventKind
    public var notificationMatcher: String?
    /// Appended to the user message on a digit-grounding retry (open issue #9):
    /// names the ungrounded number(s) so the model can remove or correct them.
    /// Never set on a first attempt.
    public var correctiveNote: String?
    /// Required only by managed composition. Never inferred from a rowid/fork.
    public var managedSource: GatewaySource?

    public init(
        lastAssistantMessage: String,
        projectLabel: String,
        firstUserMessage: String? = nil,
        previousGoal: String? = nil,
        gitBranch: String? = nil,
        cwd: String? = nil,
        hookEvent: HookEventKind = .stop,
        notificationMatcher: String? = nil,
        correctiveNote: String? = nil,
        managedSource: GatewaySource? = nil
    ) {
        self.lastAssistantMessage = lastAssistantMessage
        self.projectLabel = projectLabel
        self.firstUserMessage = firstUserMessage
        self.previousGoal = previousGoal
        self.gitBranch = gitBranch
        self.cwd = cwd
        self.hookEvent = hookEvent
        self.notificationMatcher = notificationMatcher
        self.correctiveNote = correctiveNote
        self.managedSource = managedSource
    }
}

public struct Summary: Sendable {
    public let spoken: SanitizedSpokenText
    public let brief: SessionBrief
    public let provider: String
    public let latencyMs: Int
    public let managedReceipt: GatewayReceipt?
    public let managedFailure: ManagedSummaryFailure?

    public init(spoken: SanitizedSpokenText, brief: SessionBrief, provider: String, latencyMs: Int,
                managedReceipt: GatewayReceipt? = nil, managedFailure: ManagedSummaryFailure? = nil) {
        self.spoken = spoken; self.brief = brief; self.provider = provider; self.latencyMs = latencyMs
        self.managedReceipt = managedReceipt; self.managedFailure = managedFailure
    }
}

public struct SummaryDelivery: Sendable {
    public let brief: SessionBrief
    public let receipt: GatewayReceipt?
    public init(brief: SessionBrief, receipt: GatewayReceipt? = nil) { self.brief = brief; self.receipt = receipt }
}

public protocol SummaryProvider: Sendable {
    var name: String { get }
    var isConfigured: Bool { get }
    var usesManagedCredits: Bool { get }
    func brief(for request: SummaryRequest) async throws -> SessionBrief
    func delivery(for request: SummaryRequest) async throws -> SummaryDelivery
}

public extension SummaryProvider {
    var usesManagedCredits: Bool { false }
    func delivery(for request: SummaryRequest) async throws -> SummaryDelivery {
        SummaryDelivery(brief: try await brief(for: request))
    }
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
        // Leading sentences up to the full spoken budget, not a hard two. Two
        // sentences spoke a cliffhanger and stopped ("…here's the short
        // version." — app.log 20 Aug 14:13:49); a reply's opening carries its
        // outcome, so the floor gets the same ~30 seconds a model brief gets.
        // `clamp` splits on punctuation-plus-whitespace, so `format.swift` and
        // `3.14` survive intact, and it never cuts mid-sentence.
        let happened = SpokenTextSanitizer.clamp(
            request.lastAssistantMessage.replacingOccurrences(of: "\n", with: " "),
            maxWords: SpokenTextSanitizer.maxWords)
        return SessionBrief(
            topic: request.projectLabel,
            happened: happened.isEmpty ? "finished a turn" : happened,
            branch: request.gitBranch)
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

    // The prompt was rewritten 14 Sep 2026 (ruled by Robert the same day): the
    // JSON is two objects, `spoken` in the order it is spoken and `written` for
    // the page; no risk field, no card fields, no label prefix, no callsign.
    // The old prompt's lineage (tools/replay/prompts/) is history, not a
    // second source of truth. Read it back with `tbase replay-log --dry`.
    //
    /// The user half of the prompt, assembled from the request.
    ///
    /// Extracted 19 Aug so a prompt change can be ASSERTED. The goal rung's
    /// whole mechanism is that a carried value reaches the model framed as
    /// state to keep, while the opening ask in the same prompt is framed as
    /// stale background to ignore — two blocks whose difference is the feature,
    /// and neither was reachable from a test while this lived inside a function
    /// that needs an API key to run.
    public static func userPrompt(for request: SummaryRequest) -> String {
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
        if let carried = request.previousGoal, !carried.isEmpty {
            // Verbatim, and named as the thing to keep. Framed the opposite way
            // to the opening ask above: that one is stale background the model
            // must not narrate, this one is current state it must not lose.
            context += """


                The goal this session is already carrying. KEEP IT WORD FOR WORD \
                unless this turn shows the work has moved to something it does \
                not cover:
                \(carried)
                """
        }
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
        return user
    }

    public static func systemPrompt(projectLabel: String) -> String { """
        You are the dispatcher for a developer running many coding-agent sessions at \
        once. One just finished a turn. Write the ONE spoken update they will hear \
        about it: short, exact, with one decision. Then what the hub page will show.

        Reply with ONLY this JSON object, no prose and no code fence:

        {
          "spoken": {
            "recap":     "what concluded this turn, TEN WORDS MAX",
            "proposal":  "the one next action, ending in a one-word question, TWELVE WORDS MAX",
            "goal":      "what this session is for: We are [doing X] [for Y] in [Z]",
            "findings":  "what the work turned up, TWENTY-FIVE WORDS MAX, or null",
            "solution":  "the shape of what is proposed, TWENTY-FIVE WORDS MAX, or null",
            "rationale": "why this proposal, with the risk if there is one, TWENTY-FIVE WORDS MAX, or null"
          },
          "written": {
            "headline":  "the finding, EIGHT WORDS MAX, or null",
            "deck":      "where things stand and what is left, TWENTY WORDS MAX, or null"
          }
        }

        ── SPOKEN: read aloud, in this order ──

        recap and proposal are heard every time, straight after the turn ends. goal, \
        findings, solution and rationale are heard one at a time, only when the \
        listener asks for more. The word caps are hard limits, not targets: shorter is \
        always right. Every field says something the fields before it did not. If a \
        field has nothing new to add, it is null, and a null field is simply not \
        spoken. Never restate an earlier field to fill a later one.

        recap: what concluded, with its exact parameters. Numbers and specifics beat \
        adjectives: "three alerts posted", not "some alerts". Never speak a number that \
        is not in the source message.

        proposal: ONE action, taken only from the agent's final message, specific and \
        parameterized, ending in a decision answerable in one word: "Go?", "Ship it?". \
        If the source offers alternatives, name the agent's preferred one and ask. If \
        the message proposes nothing, asks nothing, and does not end on an open thread, \
        close plainly with no question. If the action is destructive or hard to reverse \
        (deletes, force-pushes, sends to real people, spends money), say so here, in a \
        clause. The listener answers without opening the tab: "yes" must be a complete \
        and safe reply.

        findings: what the work TURNED UP, not what was done: results, numbers, \
        discoveries, surprises, failures. "Recovered three misfiled pieces; the scanner \
        missed one class entirely" is findings; "audited the directory" is not. null \
        when the turn produced none; inventing some is the worst failure available.

        solution: the concrete shape of the proposed work: the pieces and their order. \
        If the source ranks items, speak the count and the top ones. null when nothing \
        is proposed.

        rationale: "We propose X because Y. We need to be careful about Z." Y is the \
        reason for this action now, from the agent's final message. Z is the main risk \
        and what breaks if it goes wrong; if there is no real risk, leave Z out rather \
        than hedging. Name X concretely; "we propose addressing this" is a failure \
        because the listener cannot resolve "this". null when the turn is closed with \
        nothing behind it.

        Speech: no file paths, branch names, function or variable names, hashes or \
        UUIDs; describe them ("the asset pool"). Product, project and service names ARE \
        speakable: say "Klaviyo", not "an email platform". Numbers as separate words: \
        "twenty-two ninety-four", "four and a half hours". Easy to understand speech. \
        No lists, no labels. Assume the listener hears this once. Never use an em dash \
        in any field; use a period, comma or colon.

        ── "goal": what this session is for ──

        The operator stepped away from ten running sessions and is coming back. This is \
        the ten words that tell them WHICH one this is and WHAT it is for.

        The shape, as guidance and not a form to fill in:

            WE ARE [doing X] [to/for Y] IN [Z].

            "We are fixing the subject line versus title split in the kopi editor"
            "We are analyzing Klaviyo flow health for U Vape in Kopi"
            "We are working out why Time Machine backups take twenty four hours"
            "We are fixing a bug where clicking a lamp wouldn't turn it off, in \
        tranquility base"

        ALWAYS begin with "We are", then the verb in the present continuous. Z lands at \
        the end; the word "project" is never needed.

        Z MUST BE A NAME THE WORK ITSELF USES. If this turn does not name a product, \
        repository, brand or account, leave the trailing "in Z" off entirely: an \
        invented Z is far worse than none, because it is read as fact. Two real answers \
        got this wrong: "in Klaviyo" about a MAILCHIMP audit, and "in robertnowell's \
        Mac" appended to a goal whose subject was already Time Machine.

        The PROJECT is the product, repository, brand, machine or account the work is \
        IN, and it is the name a person says out loud. It is not the directory the \
        agent is running from: a session started in Projects may be working in kopi \
        dot ai. It is never a class, a file or a symbol: StatusHUD is a file inside \
        tranquility base, not a project. The PROBLEM is what is wrong or what is being \
        built, the thing itself rather than the method.

        Match the LENGTH of the examples: what a person says out loud in one breath. \
        No number is given, deliberately; the examples are the specification. The extra \
        words are always method, tooling or a standard's name, and none of those is \
        the work.

        If a goal is carried in the message below, COPY IT VERBATIM. Do not tidy it or \
        re-word it. Replace it only when this turn shows the session is now doing \
        something the carried goal does not cover, and then write the NEW aim.

        ── WRITTEN: read on the page, never spoken ──

        headline names the FINDING, not the topic: "Input Monitoring is required after \
        all" beats "permission validation". deck says where things stand and what is \
        left, including the cost of agreeing when there is one. Both may name symbols \
        and paths precisely, because they are read. Both null when the turn was pure \
        plumbing with nothing to promote. The caps are hard limits here too.

        ── GROUNDING: overrides everything above ──

        Every fact, and especially the proposal, comes from the agent's final message. \
        If it does not say what comes next, say what happened and stop; never invent a \
        next task, and never take one from how the session opened. The work was done by \
        the agent, not the user: "the session validated", never "you validated". A \
        session with a next step always needs a reply; never say no input is needed.

        If the message says the session is BLOCKED and waiting, say what it wants to do \
        and what the decision is.

        ── EXAMPLES: real turns, at the length wanted ──

        Source: a watchdog for the audio daemon was redesigned after review closed a \
        wildcard sudo path and an unasked restart; a one-time install proves the rule.
        {"spoken": {"recap": "Audio watchdog design locked in, PR three twenty nine \
        auto-merging.", "proposal": "Install it once with your password to prove the \
        sudo rule. Go?", "goal": "We are finding why tranquility base fails when \
        sharing audio on Zoom", "findings": "The probe reads the audio daemon every \
        twenty seconds with an eight second timeout, so Bluetooth renegotiation never \
        trips it.", "solution": "One installer run proves the sudo rule with a three \
        second dump of the healthy daemon; capture only by default.", "rationale": "We \
        propose installing because the first draft's wildcard sudo path and unasked \
        restart are both closed. We need to be careful: installation runs root \
        commands."}, "written": {"headline": "Sudo hole closed, daemon restart moved to \
        you", "deck": "The watchdog captures audio daemon state safely; installing \
        proves the design. Whether you need the answer is still open."}}

        Source: research on a simplified token sign-in finished with three decisions \
        for the user and nothing to build yet.
        {"spoken": {"recap": "Research complete; three decisions sit at the top of the \
        page.", "proposal": "Review grant spend, zero-balance behavior and the grant \
        gate. Proceed?", "goal": "We are designing a simplified token sign-in for \
        Tranquility Base", "findings": "Voice is sixty-eight percent of cost. Only \
        Tranquility Base degrades instead of stopping at zero. Email codes are weakest, \
        capped at three dollars thirty-three.", "solution": null, "rationale": "We \
        propose deciding now because the research settled the tradeoffs: voice \
        dominates cost, degradation is yours alone, and email codes are weak but \
        capped."}, "written": {"headline": "Three decisions ready: spend, degradation, \
        gate", "deck": "Research complete. Voice dominates cost, you alone degrade \
        gracefully, email codes are weakest but capped. Choose each tradeoff."}}
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

        let user = Self.userPrompt(for: request)
        let system = Self.systemPrompt(projectLabel: request.projectLabel)
        let completion = try await complete(system: system, user: user)
        return try Self.parse(completion.text, request: request)
    }

    /// One model call, exactly as `brief(for:)` makes it: the same body, the
    /// same headers, the same log line. Factored out 14 Sep so a replay can
    /// send a HISTORICAL user prompt (the context production actually
    /// compiled, read back from the model-call log) under the system prompt
    /// compiled from THIS build, and get a real answer, not a simulation.
    /// `log: false` keeps a replay out of the production corpus.
    public struct Completion: Sendable {
        public let text: String
        public let raw: String
        public let elapsedMs: Int
    }

    public func complete(system: String, user: String, log: Bool = true) async throws -> Completion {
        guard let key = Secrets.read(.anthropicAPIKey) else { throw SummaryError.notConfigured }
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

        let raw = String(data: data, encoding: .utf8) ?? "<undecodable>"
        if log {
            ModelCallLog.record(
                model: model, status: http.statusCode, elapsedMs: elapsedMs,
                system: system, user: user, response: raw)
        }
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
        return Completion(text: text, raw: raw, elapsedMs: elapsedMs)
    }

    public static func parse(_ text: String, request: SummaryRequest) throws -> SessionBrief {
        // Tolerate a stray code fence or leading prose.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw SummaryError.unparseable(String(text.prefix(120)))
        }
        let jsonSlice = String(text[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw SummaryError.unparseable(String(jsonSlice.prefix(120))) }

        // Two shapes. The current one nests `spoken` and `written` (14 Sep);
        // the flat one is what the managed gateway and every response before
        // 14 Sep return. A flat response still parses so a gateway that has
        // not moved yet keeps announcing.
        let spoken = obj["spoken"] as? [String: Any] ?? obj
        let written = obj["written"] as? [String: Any] ?? obj
        func field(_ key: String, in dict: [String: Any]) -> String? {
            guard let raw = dict[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty || trimmed.lowercased() == "null") ? nil : trimmed
        }

        let recap = field("recap", in: spoken)
        // `happened` is the store's non-optional column and the hub's turn
        // body. It is the recap now: what the agent did this turn. A flat,
        // older response may carry its own.
        guard let happened = recap ?? field("happened", in: obj) else {
            throw SummaryError.unparseable("no recap")
        }
        let headline = field("headline", in: written)
        return SessionBrief(
            // The hub lists a turn by its headline and falls back to `topic`;
            // there is no topic field any more, so the fallback is the recap.
            topic: field("topic", in: obj) ?? headline ?? happened,
            goal: field("goal", in: spoken),
            happened: happened,
            nextStep: field("nextStep", in: obj),
            question: field("question", in: obj),
            risk: field("risk", in: obj),
            rationale: field("rationale", in: spoken),
            findings: field("findings", in: spoken),
            solution: field("solution", in: spoken),
            branch: request.gitBranch,
            recap: recap,
            proposal: field("proposal", in: spoken),
            headline: headline,
            deck: field("deck", in: written))
    }
}

// MARK: - Chain

/// Tries providers in order and always returns something. A silent loop is a broken
/// loop, so the last provider is the deterministic floor.
public struct SummarizerChain: Sendable {
    public let providers: [any SummaryProvider]
    public let sanitizer = SpokenTextSanitizer()
    /// Pull requests are not the summariser's business at all. The hub asks
    /// GitHub what pull request a BRANCH has, and `branch` is already
    /// deterministic here. See `GitHubPullRequests`.

    public init(providers: [any SummaryProvider]? = nil) {
        self.providers = providers ?? [AnthropicSummaryProvider(), DeterministicSummarizer()]
    }

    /// Explicit composition. Managed errors may use the free floor, never BYOK.
    public init(managed provider: ManagedSummaryProvider) { self.providers = [provider] }

    /// Set by the app so grounding retries and empty-source skips explain themselves.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// `lexicon` (A7) joins the per-message allowlist: names established by
    /// RECENT sessions stay speakable even when this one message did not
    /// capitalize them. Like the per-message set, it can only exempt tokens
    /// from the identifier rules — paths and hashes are stripped regardless.
    public func summarize(_ request: SummaryRequest, lexicon: Set<String> = []) async -> Summary {
        let start = Date()
        var produced: (SessionBrief, String)?
        var managedReceipt: GatewayReceipt?
        var managedFailure: ManagedSummaryFailure?

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
                do {
                    let delivery = try await provider.delivery(for: request)
                    let grounded = await groundDigits(delivery.brief, request: request, provider: provider)
                    produced = (grounded.brief,
                                provider.name + (grounded.scrubbed ? "+digit-scrubbed" : ""))
                    managedReceipt = delivery.receipt
                    break
                } catch {
                    if provider.usesManagedCredits {
                        managedFailure = (error as? ManagedSummaryFailure) ?? .refused(code: "service_unavailable", operationId: nil)
                        break
                    }
                }
            }
        }
        // A cancelled call must not manufacture a floor. When the announce task
        // is cancelled mid-summarize, the model call above dies of that same
        // cancellation and `try?` makes it look like a provider failure — and
        // the floor built here then gets spoken, or re-prepared, as if it were
        // real (app.log 20 Aug 14:13:49). Leave `produced` nil instead; the
        // "none" summary is never persisted, and the speak path gates on the
        // same cancellation.
        if produced == nil, !Task.isCancelled,
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
            latencyMs: Int(Date().timeIntervalSince(start) * 1000),
            managedReceipt: managedReceipt, managedFailure: managedFailure)
    }

    /// Digit grounding (open issue #9): a number the source never said must not be
    /// spoken. One corrective retry; if the retry still invents numbers, the
    /// offending clauses are scrubbed rather than spoken — a summary missing a
    /// clause beats a confident wrong number, and this path must never crash.
    private func groundDigits(
        _ brief: SessionBrief, request: SummaryRequest, provider: any SummaryProvider
    ) async -> (brief: SessionBrief, scrubbed: Bool) {
        let pool = DigitGrounding.sourcePool(for: request)
        if provider.usesManagedCredits {
            // Paid retries belong inside the Gateway operation. Validate actual
            // speech locally, including legacy cards without recap and the card
            // fallback exposed when a scrub removes the entire recap.
            var safe = brief
            var scrubbed = false
            for _ in 0..<2 {
                var spoken = safe; spoken.recap = safe.spokenText(); spoken.proposal = nil
                let offending = DigitGrounding.ungroundedTokens(in: spoken, pool: pool)
                guard !offending.isEmpty else { break }
                let tokens = Set(offending)
                safe = DigitGrounding.scrub(safe, tokens: tokens)
                if safe.recap?.isEmpty != false {
                    safe.topic = DigitGrounding.scrubText(safe.topic, tokens: tokens)
                    if safe.topic.isEmpty { safe.topic = request.projectLabel }
                }
                scrubbed = true
            }
            return (safe, scrubbed)
        }
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
