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

    /// A barge-in is an event, as of 29 Sep. It was not: the turn was cut, the
    /// voice stopped, and nothing said so -- so neither the log nor the panel
    /// could tell a line that was cut off from one that finished.
    func testAnInterruptionParsesAndCarriesTheLineItCut() throws {
        let line = #"{"event":"interrupted","t":1790.5,"id":"9f2a1c04","chars":63,"voice":"manager","took":1.4}"#
        let e = try XCTUnwrap(ManagerEvent.parse(Data(line.utf8)))
        XCTAssertEqual(e.event, .interrupted)
        XCTAssertEqual(e.took, 1.4)
        XCTAssertEqual(e.voice, "manager")
    }

    /// A stop now names the line it stopped and how long it ran. The duration
    /// is fractional, and `secs` is an Int: decoding one into the other fails
    /// the WHOLE event, so the panel would have received no `quiet` at all and
    /// left every cut line half lit. Written after doing exactly that.
    func testAStopWithADurationStillParses() throws {
        let line = #"{"event":"quiet","t":1790.9,"id":"9f2a1c04","chars":63,"voice":"manager","took":12.3}"#
        let e = try XCTUnwrap(ManagerEvent.parse(Data(line.utf8)))
        XCTAssertEqual(e.event, .quiet)
        XCTAssertEqual(e.took, 12.3)
        XCTAssertNil(e.secs, "the session's own clock is a different field")
    }

    /// And the whole-second one the session's life uses is untouched.
    func testIdleStillCarriesWholeSeconds() throws {
        let e = try XCTUnwrap(ManagerEvent.parse(Data(#"{"event":"idle","secs":1200}"#.utf8)))
        XCTAssertEqual(e.secs, 1200)
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
