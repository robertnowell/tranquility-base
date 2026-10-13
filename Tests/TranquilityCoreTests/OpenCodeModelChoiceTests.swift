import XCTest
@testable import TranquilityCore

final class OpenCodeModelChoiceTests: XCTestCase {
    func testConfigModelSplitsProviderFromTheRestEvenWithSlashesInTheModel() {
        let data = Data("""
        {
          // the user's own choice
          "$schema": "https://opencode.ai/config.json",
          "model": "openrouter/anthropic/claude-fable-5.1"
        }
        """.utf8)
        XCTAssertEqual(OpenCodeModelChoice.fromConfig(data),
                       .init(providerID: "openrouter", modelID: "anthropic/claude-fable-5.1"))
        XCTAssertNil(OpenCodeModelChoice.fromConfig(Data("{\"theme\":\"x\"}".utf8)))
        XCTAssertNil(OpenCodeModelChoice.parse("no-slash"))
    }

    func testTUIStateIsTheMostRecentPickWithItsVariant() {
        let data = Data("""
        {"recent":[{"providerID":"openrouter","modelID":"anthropic/claude-fable-5.1"}],
         "favorite":[],"variant":{"openrouter/anthropic/claude-fable-5.1":"medium"}}
        """.utf8)
        let chosen = OpenCodeModelChoice.fromState(data)
        XCTAssertEqual(chosen, .init(providerID: "openrouter", modelID: "anthropic/claude-fable-5.1",
                                     variant: "medium"))
        XCTAssertEqual(chosen?.ref, ["providerID": "openrouter", "id": "anthropic/claude-fable-5.1",
                                     "variant": "medium"])
        XCTAssertNil(OpenCodeModelChoice.fromState(Data("{\"recent\":[]}".utf8)))
    }

    func testConfigOutranksStateAndNothingMeansNil() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("occhoice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(OpenCodeModelChoice.preferred(home: home))

        let state = home.appendingPathComponent(".local/state/opencode")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data(#"{"recent":[{"providerID":"openrouter","modelID":"a/b"}]}"#.utf8)
            .write(to: state.appendingPathComponent("model.json"))
        XCTAssertEqual(OpenCodeModelChoice.preferred(home: home)?.modelID, "a/b")

        let config = home.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"model":"anthropic/c"}"#.utf8).write(to: config.appendingPathComponent("opencode.json"))
        XCTAssertEqual(OpenCodeModelChoice.preferred(home: home),
                       .init(providerID: "anthropic", modelID: "c"))
    }
}
