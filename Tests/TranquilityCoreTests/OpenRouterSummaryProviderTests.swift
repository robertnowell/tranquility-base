import XCTest
@testable import TranquilityCore

/// Own-key summaries on OpenRouter (ruled 5 Oct 2026). Nothing here touches
/// the network: the request is built and read back, and the reply parser is
/// fed literal JSON.
final class OpenRouterSummaryProviderTests: XCTestCase {

    private func built() throws -> (URLRequest, [String: Any]) {
        let req = try OpenRouterSummaryProvider.request(
            model: OpenRouterSummaryProvider.defaultModel, key: "probe",
            system: "SYSTEM", user: "USER", timeout: 20)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        return (req, body)
    }

    func testTheRequestGoesToOpenRouterWithABearerKey() throws {
        let (req, _) = try built()
        XCTAssertEqual(req.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer probe")
        XCTAssertEqual(req.timeoutInterval, 20)
    }

    /// Each setting is a measurement: low reasoning (37 s at the default),
    /// JSON output, and room for the whole brief (one in sixty truncated).
    func testTheBodyPinsModelJsonReasoningAndCeiling() throws {
        let (_, body) = try built()
        XCTAssertEqual(body["model"] as? String, "google/gemini-3.8-flash")
        XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(body["max_tokens"] as? Int, 2048)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.map { $0["content"] }, ["SYSTEM", "USER"])
    }

    func testTheReplyTextIsTheFirstChoice() {
        let reply = #"{"choices":[{"finish_reason":"stop","message":{"content":" {\"spoken\":{\"recap\":\"We merged it.\"}} "}}]}"#
        XCTAssertEqual(OpenRouterSummaryProvider.text(from: Data(reply.utf8)), #"{"spoken":{"recap":"We merged it."}}"#)
    }

    /// A reply cut off by the ceiling is unusable JSON; it reads as empty so
    /// the chain moves on instead of parsing half a brief.
    func testATruncatedReplyIsEmpty() {
        let reply = #"{"choices":[{"finish_reason":"length","message":{"content":"{\"spoken\":{\"recap\":\"We mer"}}]}"#
        XCTAssertNil(OpenRouterSummaryProvider.text(from: Data(reply.utf8)))
    }

    /// Own-key rungs: OpenRouter first, Anthropic after it for keys stored
    /// before 5 Oct, then the floor.
    func testTheChainTriesOpenRouterBeforeAnthropic() {
        XCTAssertEqual(SummarizerChain.ownKeyProviders.map(\.name), ["openrouter", "anthropic"])
        XCTAssertEqual(SummarizerChain().providers.map(\.name), ["openrouter", "anthropic", "deterministic"])
    }
}
