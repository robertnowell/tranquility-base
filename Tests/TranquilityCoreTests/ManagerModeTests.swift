import Foundation
import XCTest
@testable import TranquilityCore

final class ManagerModeTests: XCTestCase {
    func testParsesAGateVerdictLine() throws {
        let line = #"{"event":"addressed","t":1789.5,"p":0.98,"intent":"invite_next","ms":155,"text":"Tranquility, invite the next agent"}"#
        let e = try XCTUnwrap(ManagerEvent.parse(Data(line.utf8)))
        XCTAssertEqual(e.event, .addressed)
        XCTAssertEqual(e.p, 0.98)
        XCTAssertEqual(e.intent, "invite_next")
    }

    func testParsesAStageLineAndIgnoresUnknownFields() throws {
        let line = #"{"event":"stage","session":"abc","goal":"ship the CRM","project":"outreach","extra":1}"#
        let e = try XCTUnwrap(ManagerEvent.parse(Data(line.utf8)))
        XCTAssertEqual(e.event, .stage)
        XCTAssertEqual(e.goal, "ship the CRM")
    }

    func testHearingAndErrorParse() throws {
        XCTAssertEqual(try XCTUnwrap(ManagerEvent.parse(Data(#"{"event":"hearing"}"#.utf8))).event, .hearing)
        let e = try XCTUnwrap(ManagerEvent.parse(Data(#"{"event":"error","reason":"tbase missing"}"#.utf8)))
        XCTAssertEqual(e.reason, "tbase missing")
    }

    func testAnUnknownEventKindIsNotAnEvent() {
        XCTAssertNil(ManagerEvent.parse(Data(#"{"event":"dance"}"#.utf8)))
        XCTAssertNil(ManagerEvent.parse(Data("not json".utf8)))
    }

    func testCommandDefaultsBesideTheCheckoutAndHonoursConfig() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hq-\(UUID().uuidString).json")
        XCTAssertTrue(ManagerConfig.command(config: tmp).first?.hasSuffix("tb-voice/server/run.sh") ?? false)
        try #"{"manager":{"command":["/usr/local/bin/tb-voice","--quiet"]}}"#.write(to: tmp, atomically: true, encoding: .utf8)
        XCTAssertEqual(ManagerConfig.command(config: tmp), ["/usr/local/bin/tb-voice", "--quiet"])
    }

    func testEnvironmentMarksTheHostAndExtendsPath() {
        let env = ManagerConfig.environment(base: ["PATH": "/x"])
        XCTAssertEqual(env["TB_HOST"], "app")
        XCTAssertTrue(env["PATH"]?.hasSuffix(":/x") ?? false)
        XCTAssertTrue(env["PATH"]?.contains("/.local/bin") ?? false)
    }
}
