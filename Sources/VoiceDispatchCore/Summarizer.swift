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

    public init(
        lastAssistantMessage: String,
        projectLabel: String,
        firstUserMessage: String? = nil,
        gitBranch: String? = nil,
        cwd: String? = nil,
        hookEvent: HookEventKind = .stop,
        notificationMatcher: String? = nil
    ) {
        self.lastAssistantMessage = lastAssistantMessage
        self.projectLabel = projectLabel
        self.firstUserMessage = firstUserMessage
        self.gitBranch = gitBranch
        self.cwd = cwd
        self.hookEvent = hookEvent
        self.notificationMatcher = notificationMatcher
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

    static let systemPrompt = """
        You are the dispatcher for a developer running many coding-agent sessions at \
        once. One just finished a turn. Your job is to let them decide what to do next \
        without opening the tab.

        Reply with ONLY a JSON object, no prose and no code fence:

        {
          "spoken":   "ONE sentence, 22 words max, that will be READ ALOUD",
          "topic":    "3-6 words naming this work, for a list",
          "goal":     "what this session is trying to achieve, or null",
          "happened": "what just concluded, one clause",
          "nextStep": "the proposed next action, or null",
          "question": "a real question being put to the user, or null",
          "risk":     "a risk worth knowing before deciding, or null"
        }

        The "spoken" field is the only part the user hears. Write it the way you would \
        SAY it to someone across the room who has been working on something else:
        - Name the work in ordinary words. "The Kopi promo email" — not "saved-edit \
        template image linkage".
        - Say plainly whether it worked, or is stuck, or found something.
        - End with what you want from them: the question, or the next step you propose.
        - Never say a function name, variable name, file, branch, or identifier out \
        loud. If you cannot say it in plain English, describe it instead: "the asset \
        pool" rather than the actual symbol.
        - It must sound like a person talking. Not a headline, not a ticket title, not \
        a noun phrase. Full sentence, verb included.

        For the other fields: 12 words or fewer each, same no-identifiers rule. Use \
        null when a field genuinely does not apply — never invent a question or a risk.
        """

    public func brief(for request: SummaryRequest) async throws -> SessionBrief {
        guard let key = Secrets.read(.anthropicAPIKey) else { throw SummaryError.notConfigured }

        if request.hookEvent == .notification {
            // An LLM adds nothing to "it wants permission" — and this must be instant.
            return try await DeterministicSummarizer().brief(for: request)
        }

        var context = "Project: \(request.projectLabel)"
        if let branch = request.gitBranch { context += "\nBranch: \(branch)" }
        if let ask = request.firstUserMessage {
            context += "\n\nWhat the user originally asked for:\n\(ask)"
        }

        let user = """
            \(context)

            The agent's final message this turn:
            \(request.lastAssistantMessage)
            """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 400,
            "system": Self.systemPrompt,
            "messages": [["role": "user", "content": user]],
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SummaryError.emptyResponse }
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
            branch: request.gitBranch,
            spoken: field("spoken"))
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
    public var resolvePullRequests: Bool

    public init(providers: [any SummaryProvider]? = nil, resolvePullRequests: Bool = true) {
        self.providers = providers ?? [AnthropicSummaryProvider(), DeterministicSummarizer()]
        self.resolvePullRequests = resolvePullRequests
    }

    public func summarize(_ request: SummaryRequest) async -> Summary {
        let start = Date()
        var produced: (SessionBrief, String)?

        for provider in providers where provider.isConfigured {
            if let brief = try? await provider.brief(for: request) {
                produced = (brief, provider.name)
                break
            }
        }
        if produced == nil,
           let fallback = try? await DeterministicSummarizer().brief(for: request) {
            produced = (fallback, "deterministic-fallback")
        }

        var (brief, providerName) = produced
            ?? (SessionBrief(topic: request.projectLabel, happened: "finished a turn"), "none")

        if resolvePullRequests, let branch = request.gitBranch {
            brief.pullRequest = PullRequestLookup.forBranch(branch, cwd: request.cwd)
        }

        return Summary(
            spoken: sanitizer.sanitize(brief.spokenText()),
            brief: brief,
            provider: providerName,
            latencyMs: Int(Date().timeIntervalSince(start) * 1000))
    }
}
