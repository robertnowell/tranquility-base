import Foundation

// MARK: - Contract

public struct SummaryRequest: Sendable {
    public var lastAssistantMessage: String
    public var projectLabel: String
    public var hookEvent: HookEventKind
    public var notificationMatcher: String?

    public init(
        lastAssistantMessage: String,
        projectLabel: String,
        hookEvent: HookEventKind = .stop,
        notificationMatcher: String? = nil
    ) {
        self.lastAssistantMessage = lastAssistantMessage
        self.projectLabel = projectLabel
        self.hookEvent = hookEvent
        self.notificationMatcher = notificationMatcher
    }
}

public struct Summary: Sendable {
    public let spoken: SanitizedSpokenText
    public let provider: String
    public let latencyMs: Int
}

public protocol SummaryProvider: Sendable {
    var name: String { get }
    var isConfigured: Bool { get }
    func summarize(_ request: SummaryRequest) async throws -> String
}

public enum SummaryError: Error, Sendable {
    case notConfigured
    case http(Int, String)
    case emptyResponse
    case timedOut
}

// MARK: - The floor
//
// Never fails, never calls anything. If every other provider is down, the loop
// still says something true rather than going silent.

public struct DeterministicSummarizer: SummaryProvider {
    public let name = "deterministic"
    public let isConfigured = true
    public init() {}

    public func summarize(_ request: SummaryRequest) async throws -> String {
        if request.hookEvent == .notification {
            return Self.notificationLine(request)
        }
        let firstSentences = Self.firstSentences(
            of: request.lastAssistantMessage.replacingOccurrences(of: "\n", with: " "), count: 2)

        if firstSentences.isEmpty {
            return "\(request.projectLabel) finished a turn."
        }
        let needsStop = !".!?".contains(firstSentences.last ?? " ")
        return "\(request.projectLabel): \(firstSentences)\(needsStop ? "." : "")"
    }

    /// Split on sentence-ending punctuation followed by whitespace — never on a bare
    /// `.`, which would cut `format.swift` and `3.14` in half and leave debris that
    /// the sanitizer can no longer recognise as a filename.
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
        case "permission_prompt":
            return "\(request.projectLabel) is waiting for permission to continue."
        case "idle_prompt":
            return "\(request.projectLabel) has been idle and is waiting on you."
        case "agent_needs_input":
            return "\(request.projectLabel) needs input before it can carry on."
        default:
            return "\(request.projectLabel) needs your attention."
        }
    }
}

// MARK: - Anthropic

/// A summarizer is a pure function of the agent's last message, so it gets a plain
/// API call rather than a `claude -p` subprocess. A subprocess would load global
/// CLAUDE.md, auto-memory, skills, MCP servers, and every SessionStart hook in order
/// to write thirty words — slow, unpredictable, and it fires its own Stop hook.
public struct AnthropicSummaryProvider: SummaryProvider {
    public let name = "anthropic"
    public var model: String
    public var timeout: TimeInterval

    public init(model: String = "claude-haiku-4-5-20251001", timeout: TimeInterval = 12) {
        self.model = model
        self.timeout = timeout
    }

    public var isConfigured: Bool { Secrets.has(.anthropicAPIKey) }

    static let systemPrompt = """
        You write a single short notification that will be read aloud by a speech \
        synthesizer to a developer who stepped away from a coding agent.

        Rules:
        - 35 words maximum. Shorter is better. One or two sentences.
        - Say what was concluded. Then the single most important concern, if there is a \
        real one. Then the suggested next step, if there is a real one. Omit any beat \
        that isn't genuinely there — do not invent concerns.
        - NEVER enumerate. If there are several problems, say how many and name only the \
        one that matters most: "Four issues, the worst being a fabricated claim about \
        stock levels." A list that runs out of room mid-item is worse than a count.
        - Never include code, file paths, file names, identifiers, commit hashes, URLs, \
        or numbers that only make sense on a screen.
        - Write as if reporting what happened, not as if describing someone else's work. \
        Never begin with "The agent", "Claude", "This session", or "It". Start with the \
        subject of the work itself.
        - Plain prose only. No markdown, no quotes, no preamble, no sign-off.
        """

    public func summarize(_ request: SummaryRequest) async throws -> String {
        guard let key = Secrets.read(.anthropicAPIKey) else { throw SummaryError.notConfigured }

        if request.hookEvent == .notification {
            // Deterministic and instant — an LLM adds nothing to "it wants permission".
            return DeterministicSummarizer.notificationLine(request)
        }

        let user = """
            Project: \(request.projectLabel)

            The agent's final message:
            \(request.lastAssistantMessage)
            """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 200,
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
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw SummaryError.http(http.statusCode, String(detail))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { throw SummaryError.emptyResponse }

        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw SummaryError.emptyResponse }
        return text
    }
}

// MARK: - Chain

/// Tries providers in order and always returns something. The last provider is the
/// deterministic floor, so `summarize` cannot fail — a silent loop is a broken loop.
public struct SummarizerChain: Sendable {
    public let providers: [any SummaryProvider]
    public let sanitizer = SpokenTextSanitizer()

    public init(providers: [any SummaryProvider]? = nil) {
        self.providers = providers ?? [
            AnthropicSummaryProvider(),
            DeterministicSummarizer(),
        ]
    }

    public func summarize(_ request: SummaryRequest) async -> Summary {
        let start = Date()
        for provider in providers where provider.isConfigured {
            do {
                let raw = try await provider.summarize(request)
                // Every path goes through the sanitizer, including the deterministic
                // one — its input is the agent's own message, which is full of paths.
                return Summary(
                    spoken: sanitizer.sanitize(raw),
                    provider: provider.name,
                    latencyMs: Int(Date().timeIntervalSince(start) * 1000))
            } catch {
                continue
            }
        }
        let fallback = (try? await DeterministicSummarizer().summarize(request)) ?? "A session finished."
        return Summary(
            spoken: sanitizer.sanitize(fallback),
            provider: "deterministic-fallback",
            latencyMs: Int(Date().timeIntervalSince(start) * 1000))
    }
}
