import XCTest
@testable import TranquilityCore

final class ClaudeHealthTests: XCTestCase {

    func testAnsweredIsHealthy() {
        XCTAssertEqual(ClaudeHealth.classify(.answered).kind, .healthy)
    }

    func testBinaryMissing() {
        XCTAssertEqual(ClaudeHealth.classify(.binaryMissing).kind, .binaryMissing)
    }

    func testTimedOutIsHang() {
        XCTAssertEqual(ClaudeHealth.classify(.timedOut).kind, .startupHang)
    }

    func testFailedIsStartupErrorAndCarriesEvidence() {
        let v = ClaudeHealth.classify(.failed(tail: "Error: cannot find module mcp-server.mjs"))
        XCTAssertEqual(v.kind, .startupError)
        XCTAssertTrue(v.evidence.contains("mcp-server.mjs"), v.evidence)
    }

    // Probe with an injected runner: no real claude.

    func testProbeHealthyWhenTokenComesBack() {
        let v = ClaudeHealth.probe(runner: { _, _ in .success("here you go: tbhealthok\n") })
        XCTAssertEqual(v.kind, .healthy)
    }

    func testProbeStartupErrorWhenExitZeroButNoToken() {
        // Exit 0 but the turn produced no token: a non-fatal fault swallowed it.
        let v = ClaudeHealth.probe(runner: { _, _ in .success("(no answer)\n") })
        XCTAssertEqual(v.kind, .startupError)
    }

    func testProbeStartupErrorOnNonZeroExit() {
        let v = ClaudeHealth.probe(runner: { _, _ in
            .failure(ScriptError(message: "plugin load failed: bad hooks.json"))
        })
        XCTAssertEqual(v.kind, .startupError)
        XCTAssertTrue(v.evidence.contains("hooks.json"), v.evidence)
    }

    func testProbeHangOnTimeout() {
        let v = ClaudeHealth.probe(runner: { _, _ in
            .failure(ScriptError(message: "killed after 45s deadline", timedOut: true))
        })
        XCTAssertEqual(v.kind, .startupHang)
    }
}
