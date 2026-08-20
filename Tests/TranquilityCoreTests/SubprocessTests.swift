import XCTest
@testable import TranquilityCore

final class SubprocessTests: XCTestCase {

    func testRunCapturesStdout() {
        let out = Subprocess.run("/bin/echo", ["hello"], timeout: 5)
        guard case .success(let text) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(text, "hello")
    }

    func testDeadlineKillsAndSaysSo() {
        let start = Date()
        let out = Subprocess.run("/bin/sleep", ["30"], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        guard case .failure(let error) = out else { return XCTFail("expected timeout") }
        XCTAssertTrue(error.timedOut)
    }

    func testNonZeroExitCarriesStderr() {
        let out = Subprocess.run("/bin/sh", ["-c", "echo nope >&2; exit 3"], timeout: 5)
        guard case .failure(let error) = out else { return XCTFail("expected failure") }
        XCTAssertFalse(error.timedOut)
        XCTAssertTrue(error.message.contains("nope"))
    }

    func testStdinReachesChild() {
        let out = Subprocess.run("/bin/cat", [], stdin: Data("payload".utf8), timeout: 5)
        guard case .success(let text) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(text, "payload")
    }

    func testLargeOutputDoesNotDeadlock() {
        // A child writing far past the 64KB pipe buffer must not wedge
        // against a parent blocked in wait — the drain runs concurrently.
        let out = Subprocess.run("/bin/sh", ["-c", "yes x | head -100000"], timeout: 10)
        guard case .success(let text) = out else { return XCTFail("\(out)") }
        XCTAssertGreaterThan(text.count, 150_000)
    }

    // MARK: per-element liveness decode (audit R4)

    func testLenientSessionsDecodeDropsBadRowsOnly() {
        // The REAL decode path (gate finding V12 killed the test-local copy):
        // one row missing the non-optional pid is dropped and traced, never
        // allowed to nil the machine's whole view.
        let json = """
        [{"pid": 1, "sessionId": "a", "kind": "interactive", "status": "idle"},
         {"sessionId": "missing-pid"},
         {"pid": 3, "sessionId": "c", "status": "busy"}]
        """
        let sessions = ClaudeAgentsCLI.decodeSessions(json, trace: nil)
        XCTAssertEqual(sessions?.map(\.sessionId), ["a", "c"])
    }

    func testAllRowsUndecodableReadsAsUnknownNotEmpty() {
        // nil means "could not determine"; [] means "nobody is home". A CLI
        // whose schema moved under us must produce the former (gate V1) —
        // collapsing it into [] is how one hiccup once hid every waiting
        // session.
        let sessions = ClaudeAgentsCLI.decodeSessions(
            #"[{"sessionId": "no-pid-1"}, {"sessionId": "no-pid-2"}]"#, trace: nil)
        XCTAssertNil(sessions)
        // A genuinely empty array is still honestly empty.
        XCTAssertEqual(ClaudeAgentsCLI.decodeSessions("[]", trace: nil)?.count, 0)
    }

    // MARK: shared readiness mapping

    func testClassifyCoversTheVocabulary() throws {
        func live(_ status: String, waitingFor: String? = nil) throws -> LiveSession {
            let wf = waitingFor.map { ", \"waitingFor\": \"\($0)\"" } ?? ""
            return try JSONDecoder().decode(LiveSession.self, from: Data(
                "{\"pid\": 1, \"sessionId\": \"s\", \"status\": \"\(status)\"\(wf)}".utf8))
        }
        XCTAssertEqual(Readiness.classify(nil), .notRegistered)
        XCTAssertEqual(try Readiness.classify(live("idle")), .ready)
        XCTAssertEqual(try Readiness.classify(live("busy")), .busy)
        XCTAssertEqual(try Readiness.classify(live("waiting", waitingFor: "dialog open")),
                       .waiting("dialog open"))
        XCTAssertEqual(try Readiness.classify(live("someday-new-status")), .notRegistered)
        // The dialog gate composes: waiting-at-dialog classifies as waiting
        // AND refuses dispatch, which is the #163 ruling surviving the dedupe.
        XCTAssertFalse(try Readiness.classify(live("waiting", waitingFor: "dialog open")).canDispatch)
        XCTAssertTrue(try Readiness.classify(live("waiting", waitingFor: "user input")).canDispatch)
    }
}
