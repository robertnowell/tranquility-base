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

    func testReadyParses() throws {
        XCTAssertEqual(try XCTUnwrap(ManagerEvent.parse(Data(#"{"event":"ready"}"#.utf8))).event, .ready)
    }

    func testQuietParses() throws {
        XCTAssertEqual(try XCTUnwrap(ManagerEvent.parse(Data(#"{"event":"quiet"}"#.utf8))).event, .quiet)
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

    /// Signed in is the only way to a manager other than the dev shim; the
    /// local stdio child went on 29 Sep (hf-24).
    func testAvailabilityIsTheGatewayOrNothing() {
        XCTAssertEqual(ManagerConfig.availability(signedIn: { true }), .managed)
        XCTAssertEqual(ManagerConfig.availability(signedIn: { false }), .unset)
    }

    func testAReloadLineIsNoLongerAnEvent() {
        XCTAssertNil(ManagerEvent.parse(Data(#"{"event":"reloading"}"#.utf8)))
    }
}
