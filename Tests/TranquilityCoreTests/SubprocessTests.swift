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

    func testLenientSessionsDecodeDropsBadRowsOnly() throws {
        // Private type exercised through the JSON boundary it guards: one row
        // missing the non-optional pid must not nil the machine's whole view.
        let json = """
        [{"pid": 1, "sessionId": "a", "kind": "interactive", "status": "idle"},
         {"sessionId": "missing-pid"},
         {"pid": 3, "sessionId": "c", "status": "busy"}]
        """
        struct LenientRow: Decodable {
            let session: LiveSession?
            init(from decoder: Decoder) { session = try? LiveSession(from: decoder) }
        }
        let rows = try JSONDecoder().decode([LenientRow].self, from: Data(json.utf8))
        let sessions = rows.compactMap(\.session)
        XCTAssertEqual(sessions.map(\.sessionId), ["a", "c"])
        XCTAssertEqual(rows.count - sessions.count, 1)
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
