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

    /// What a pasted key has to be reduced to before it is a header value.
    ///
    /// Trimming the ends was not enough, and the gap showed up as the least
    /// diagnosable verdict this type can produce. A key carrying ONE control
    /// character anywhere inside it makes an illegal HTTP header; Anthropic's
    /// edge answers that with a bare 400 and an empty body, which `classify`
    /// correctly refuses to blame on the key ("unexpected reply (400)") and
    /// which therefore tells the user precisely nothing. Measured 1 Sep against
    /// api.anthropic.com: every malformed KEY, of every shape tried, comes back
    /// 401 with a message; only a malformed HEADER produces the 400. So the 400
    /// was never evidence about the credential, and the credential was never
    /// the thing to fix.
    ///
    /// No provider's key contains whitespace or a control character, so
    /// removing them cannot damage a good key and repairs a paste that picked
    /// up a line break or a stray invisible on its way through a clipboard. The
    /// verification call that follows is what proves the result either way.
    public static func sanitize(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.controlCharacters.contains($0)
        }))
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
            // `/v2/voices`, which is the call the app itself makes, and NOT
            // `/v1/user`, which it never makes.
            //
            // ElevenLabs keys are scoped per endpoint group. A key created with
            // text-to-speech alone is a perfectly good key for this app and is
            // refused by `/v1/user` with a 401, because that endpoint wants
            // `user_read`. Measured 1 Sep on a first-run install: a working
            // key, a red row reading "rejected by the provider (401)", and an
            // alert telling someone to go and check for a stray space in a
            // credential that had nothing wrong with it. Verifying against a
            // permission the product does not use is not verification, it is a
            // second thing to get wrong.
            guard let url = URL(string: "https://api.elevenlabs.io/v2/voices?page_size=1")
            else { return nil }
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
