import XCTest
@testable import TranquilityCore

/// The chain's floor race (earned 19 Aug): a silently stalled cloud rung held
/// a 2m46s reply for minutes while the on-device floor — which answers such a
/// file in well under one — waited its turn in the ladder. `floorAfter` starts
/// the LAST provider alongside the ordered rungs after a budget; first success
/// wins and the loser is cancelled. What these pin: the floor actually races
/// in, a healthy cloud rung still wins without waiting out the floor, a pinned
/// single-provider chain never races (tbase's --*-only probes depend on it),
/// and a race where both lanes fail reports the ordered lane's failure.
final class FloorRaceTests: XCTestCase {

    /// Cancellation-aware stall — a rung whose upload hangs, as OpenAI's did.
    private struct Stalls: RecoveryTranscriptionProvider {
        let name = "stalls"
        let isConfigured = true
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw TranscriptionFailure.providerUnavailable("stalled to the end")
        }
    }

    private struct Says: RecoveryTranscriptionProvider {
        let name: String
        let isConfigured = true
        let text: String
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            TranscriptionResult(text: text, finality: .recoveryForcedFinal, provider: name)
        }
    }

    private struct Fails: RecoveryTranscriptionProvider {
        let name: String
        let isConfigured = true
        func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
            throw TranscriptionFailure.providerUnavailable("\(name) is down")
        }
    }

    private let file = URL(fileURLWithPath: "/tmp/floor-race-does-not-read-this.wav")

    func testFloorRacesInWhenTheOrderedRungsStall() async {
        let chain = RecoveryChain(
            providers: [Stalls(), Says(name: "floor", text: "the floor heard it")],
            maxAttemptsPerProvider: 1, backoff: [0], floorAfter: 0.1)
        let started = Date()
        let outcome = await chain.transcribe(fileAt: file)
        XCTAssertEqual(outcome.result?.text, "the floor heard it")
        XCTAssertEqual(outcome.result?.provider, "floor")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "the stalled rung was cancelled, never waited out")
    }

    func testHealthyOrderedRungWinsWithoutWaitingForTheFloor() async {
        // The floor here would stall forever if its lane were started and not
        // cancelled — so a fast finish also proves the drain cancels cleanly.
        let chain = RecoveryChain(
            providers: [Says(name: "cloud", text: "the cloud answered"), Stalls()],
            maxAttemptsPerProvider: 1, backoff: [0], floorAfter: 0.05)
        let started = Date()
        let outcome = await chain.transcribe(fileAt: file)
        XCTAssertEqual(outcome.result?.provider, "cloud")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testPinnedSingleProviderChainNeverRaces() async {
        // tbase's --apple-only / --openai-only probes exist to exercise one
        // rung ALONE; a floor race with itself would double-run it.
        let chain = RecoveryChain(
            providers: [Says(name: "only", text: "ran once, alone")],
            maxAttemptsPerProvider: 1, backoff: [0], floorAfter: 0.01)
        let outcome = await chain.transcribe(fileAt: file)
        XCTAssertEqual(outcome.result?.text, "ran once, alone")
        XCTAssertEqual(outcome.attempts, ["only: ok"])
    }

    func testBothLanesFailingReportsTheOrderedLanesFailure() async {
        let chain = RecoveryChain(
            providers: [Fails(name: "cloud"), Fails(name: "floor")],
            maxAttemptsPerProvider: 1, backoff: [0], floorAfter: 0.05)
        let outcome = await chain.transcribe(fileAt: file)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.lastFailure,
                       .providerUnavailable("cloud is down"),
                       "the ordered lane names the better provider's reason")
        XCTAssertTrue(outcome.attempts.contains { $0.hasPrefix("cloud:") })
        XCTAssertTrue(outcome.attempts.contains { $0.hasPrefix("floor:") })
    }

    func testNilFloorAfterKeepsTheSequentialLadder() async {
        let chain = RecoveryChain(
            providers: [Fails(name: "first"), Says(name: "second", text: "ladder reached me")],
            maxAttemptsPerProvider: 1, backoff: [0], floorAfter: nil)
        let outcome = await chain.transcribe(fileAt: file)
        XCTAssertEqual(outcome.result?.text, "ladder reached me")
        XCTAssertEqual(outcome.attempts.first, "first: providerUnavailable(\"first is down\")")
    }
}
