import Foundation

// MARK: - OpenRouter

/// Spoken summaries on the person's own OpenRouter key.
///
/// Ruled 5 Oct 2026 ("just take an OpenRouter key"): a pasted key runs the
/// same model the managed Gateway is moving to, so a summary on credits and a
/// summary on a pasted key sound the same. On sixty real turns scored blind
/// against the writing standard, Gemini 3.8 Flash followed it best, got the
/// most facts right and cost about a third of Haiku.
///
/// Same system prompt and same user prompt as `AnthropicSummaryProvider`, and
/// the same parser, so the only thing that differs between the two is the
/// model. The Anthropic provider stays in the chain behind this one for keys
/// people already stored.
public struct OpenRouterSummaryProvider: SummaryProvider {
    public let name = "openrouter"
    public var model: String
    public var timeout: TimeInterval

    /// OpenRouter's slug, read from its model list on 5 Oct 2026.
    public static let defaultModel = "google/gemini-3.8-flash"
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    public init(model: String = OpenRouterSummaryProvider.defaultModel, timeout: TimeInterval = 20) {
        self.model = model
        self.timeout = timeout
    }

    public var isConfigured: Bool { Secrets.has(.openRouterAPIKey) }

    public func brief(for request: SummaryRequest) async throws -> SessionBrief {
        guard Secrets.has(.openRouterAPIKey) else { throw SummaryError.notConfigured }
        // Same rule as the Anthropic provider: a notification with nothing to
        // read has nothing for a model to add.
        if request.hookEvent == .notification, request.lastAssistantMessage.isEmpty {
            return try await DeterministicSummarizer().brief(for: request)
        }
        let user = AnthropicSummaryProvider.userPrompt(for: request)
        let system = AnthropicSummaryProvider.systemPrompt(projectLabel: request.projectLabel)
        let completion = try await complete(system: system, user: user)
        return try AnthropicSummaryProvider.parse(completion.text, request: request)
    }

    /// The request, built without sending it, so its shape can be asserted.
    ///
    /// Three settings each exist because of a measurement on 5 Oct 2026.
    /// Reasoning effort low: at its default, Gemini thought for 37 seconds on
    /// one turn, and a summary gets 20; at low it answered in under two.
    /// JSON output: the prompt asks for one JSON object and nothing else.
    /// 2,048 output tokens: one reply in sixty was cut off mid-JSON, and a
    /// truncated brief costs the whole brief while tokens cost nothing.
    static func request(model: String, key: String, system: String, user: String,
                        timeout: TimeInterval) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": ["type": "json_object"],
            "reasoning": ["effort": "low"],
            "max_tokens": 2048,
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        // OpenRouter's attribution headers, so the calls are recognisable on
        // the person's own activity page.
        req.setValue("https://tranquilitybase.dev", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Tranquility Base", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// One model call. Same shape as `AnthropicSummaryProvider.complete`, so
    /// callers that name folders or replay prompts can use either.
    public func complete(system: String, user: String, log: Bool = true) async throws
        -> AnthropicSummaryProvider.Completion {
        guard let key = Secrets.read(.openRouterAPIKey) else { throw SummaryError.notConfigured }
        let req = try Self.request(model: model, key: key, system: system, user: user, timeout: timeout)

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
            throw SummaryError.http(http.statusCode, String(raw.prefix(200)))
        }
        guard let text = Self.text(from: data) else { throw SummaryError.emptyResponse }
        return AnthropicSummaryProvider.Completion(text: text, raw: raw, elapsedMs: elapsedMs)
    }

    /// The reply's text from an OpenAI-shaped chat completion. Nil when the
    /// reply was cut off: a truncated JSON brief is unusable, and naming it
    /// empty sends the chain on to the next rung rather than to a parse error.
    static func text(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        if (choice["finish_reason"] as? String) == "length" { return nil }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
