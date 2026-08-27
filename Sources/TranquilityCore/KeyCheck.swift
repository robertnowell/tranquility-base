import Foundation

/// Ask the provider whether a key actually works.
///
/// Storing a key proves nothing. A typo, a trailing space out of a password
/// manager, a revoked key, a key pasted into the wrong row: every one of them
/// saves perfectly and then fails hours later, in the away-channel, as silence
/// or as the system voice where the good one should have been. That is the worst
/// possible place to find out, because by then nothing on screen connects the
/// symptom to the cause.
///
/// So a saved key gets one cheap read-only request, and the row says what came
/// back.
///
/// THE KEY IS NEVER STORED OR RETURNED BY THIS TYPE. It takes the value, uses it
/// for one request, and reports a verdict. Nothing here logs it, and the verdicts
/// below deliberately have no associated value that could carry it.
public enum KeyCheck {

    public enum Outcome: Sendable, Equatable {
        /// The provider answered, and accepted the key.
        case working
        /// The provider answered, and refused it. This is the one that means
        /// "you pasted the wrong thing".
        case rejected(status: Int)
        /// The provider answered something we did not expect. Reported as itself
        /// rather than guessed at: a 429 or a 500 says nothing about the key, and
        /// calling either one "invalid" would send someone to rotate a key that
        /// was fine.
        case unexpected(status: Int)
        /// We never got an answer. Offline, DNS, a timeout, a captive portal.
        /// Says nothing about the key either.
        case unreachable

        /// One line for a checklist row.
        public var summary: String {
            switch self {
            case .working: return "checked, working"
            case .rejected(let status): return "rejected by the provider (\(status))"
            case .unexpected(let status): return "unexpected reply (\(status))"
            case .unreachable: return "saved, but could not reach the provider"
            }
        }

        /// Only an outright refusal is the user's problem to fix now. Everything
        /// else is saved and worth keeping: a key that could not be checked is
        /// not a key that is wrong.
        public var isBad: Bool {
            if case .rejected = self { return true }
            return false
        }
    }

    /// Status to verdict, with no network in the way, so the interesting half is
    /// testable. Every mapping here is a decision about what to TELL somebody,
    /// and each one has a wrong answer that costs them time.
    public static func classify(status: Int?, failed: Bool) -> Outcome {
        if failed || status == nil { return .unreachable }
        guard let status else { return .unreachable }
        switch status {
        case 200...299: return .working
        // 401 unauthorized and 403 forbidden both mean the provider looked at
        // this key and said no. AssemblyAI answers a bad key with 401; Anthropic
        // with 401; ElevenLabs with 401. 403 is included because a key that is
        // valid but not entitled is still a key that will not work here, and
        // "rejected" is the honest word for both.
        case 401, 403: return .rejected(status: status)
        // 429 is rate limiting and 5xx is the provider having a bad day. Neither
        // is evidence about the key, and reporting either as invalid would send
        // someone to rotate a perfectly good one.
        default: return .unexpected(status: status)
        }
    }

    /// The cheapest read-only call each provider offers.
    ///
    /// Read-only on purpose: verifying a key must never create, spend, or
    /// transcribe anything. A summarize call would have proved the same thing and
    /// billed for it.
    static func request(for key: Secrets.Key, value: String) -> URLRequest? {
        var request: URLRequest
        switch key {
        case .anthropicAPIKey:
            guard let url = URL(string: "https://api.anthropic.com/v1/models") else { return nil }
            request = URLRequest(url: url)
            request.setValue(value, forHTTPHeaderField: "x-api-key")
            // Same version the summarizer sends. An omitted version header is
            // itself a 400, which would read as a bad key.
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .elevenLabsAPIKey:
            guard let url = URL(string: "https://api.elevenlabs.io/v1/user") else { return nil }
            request = URLRequest(url: url)
            request.setValue(value, forHTTPHeaderField: "xi-api-key")
        case .assemblyAIAPIKey:
            guard let url = URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")
            else { return nil }
            request = URLRequest(url: url)
            // Raw key, no "Bearer" -- AssemblyAIFileRecovery says so in its own
            // comment, and getting this wrong would report every valid key as
            // rejected.
            request.setValue(value, forHTTPHeaderField: "Authorization")
        case .openAIAPIKey:
            guard let url = URL(string: "https://api.openai.com/v1/models") else { return nil }
            request = URLRequest(url: url)
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        }
        request.httpMethod = "GET"
        // Short: this runs while somebody watches a row. A check that hangs for
        // sixty seconds has already failed at its job even if it eventually
        // answers.
        request.timeoutInterval = 12
        return request
    }

    public static func verify(
        _ key: Secrets.Key, value: String, session: URLSession = .shared
    ) async -> Outcome {
        guard let request = request(for: key, value: value) else { return .unreachable }
        do {
            let (_, response) = try await session.data(for: request)
            return classify(status: (response as? HTTPURLResponse)?.statusCode, failed: false)
        } catch {
            // Deliberately does not log the error's description at any level that
            // could include a URL with the key in it. None of these providers put
            // the key in the URL, but the rule is cheaper to keep than to audit.
            return classify(status: nil, failed: true)
        }
    }

    /// Check what is already stored, without the caller ever handling the value.
    public static func verifyStored(
        _ key: Secrets.Key, session: URLSession = .shared
    ) async -> Outcome? {
        guard let value = Secrets.read(key) else { return nil }
        return await verify(key, value: value, session: session)
    }
}
