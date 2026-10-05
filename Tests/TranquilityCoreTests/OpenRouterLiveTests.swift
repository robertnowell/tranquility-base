import XCTest
@testable import TranquilityCore

/// One real OpenRouter call through the provider's own request and parser.
///
/// Skipped unless `TB_LIVE_OPENROUTER_KEY` is set, so CI and preflight never
/// spend money or need a key. Run it by hand when the model, the request or
/// the prompt changes:
///
///     TB_LIVE_OPENROUTER_KEY=... swift test --filter OpenRouterLiveTests
///
/// It sends the production system prompt and a user prompt built exactly as
/// the app builds one, then checks that the reply parses into a brief with a
/// spoken recap: the end-to-end path a pasted key takes, minus the Keychain.
final class OpenRouterLiveTests: XCTestCase {

    func testOneRealSummaryParses() async throws {
        guard let key = ProcessInfo.processInfo.environment["TB_LIVE_OPENROUTER_KEY"], !key.isEmpty else {
            throw XCTSkip("set TB_LIVE_OPENROUTER_KEY to make one live call")
        }
        let request = SummaryRequest(
            lastAssistantMessage: "I merged pull request 756, which stops background task notifications from "
                + "splitting an agent's turn. The Dev install passed its launch self-tests. Next I would score "
                + "six models on sixty real turns. Want me to start?",
            projectLabel: "tranquility-base", hookEvent: .stop)
        let req = try OpenRouterSummaryProvider.request(
            model: OpenRouterSummaryProvider.defaultModel, key: key,
            system: AnthropicSummaryProvider.systemPrompt(projectLabel: request.projectLabel),
            user: AnthropicSummaryProvider.userPrompt(for: request), timeout: 20)

        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: req)
        let seconds = Date().timeIntervalSince(started)
        let status = (response as? HTTPURLResponse)?.statusCode
        XCTAssertEqual(status, 200, String(decoding: data.prefix(300), as: UTF8.self))

        let text = try XCTUnwrap(OpenRouterSummaryProvider.text(from: data), "no usable reply text")
        let brief = try AnthropicSummaryProvider.parse(text, request: request)
        let recap = try XCTUnwrap(brief.recap)
        XCTAssertFalse(recap.isEmpty)
        XCTAssertLessThan(seconds, 20, "slower than the summary timeout")
        print("LIVE openrouter \(String(format: "%.1f", seconds))s recap: \(recap) | proposal: \(brief.proposal ?? "-")")
    }
}
