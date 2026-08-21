import XCTest
@testable import TranquilityCore

final class HarnessAdapterTests: XCTestCase {

    func testClaudeCodeResumeArguments() {
        let adapter = ClaudeCodeAdapter()
        XCTAssertEqual(adapter.resumeArguments(sessionId: "abc-123"), ["--resume", "abc-123"])
    }

    func testClaudeCodeCapabilitiesMatchWhatWasMeasuredLive() {
        // These are measurements (19 Aug tmux battery), not defaults — a
        // regression here silently reintroduces the strict-landing-check gap
        // the M1 gate closed.
        let caps = ClaudeCodeAdapter().capabilities
        XCTAssertTrue(caps.echoesPaste)
        XCTAssertEqual(caps.promptGlyph, "❯")
        XCTAssertTrue(caps.queuesInputMidTurn)
        XCTAssertTrue(caps.registersWithLiveness)
        XCTAssertTrue(caps.hasHooks)
    }

    func testClaudeCodeTrustPromptNeedles() {
        let spec = ClaudeCodeAdapter().trustPrompt
        XCTAssertNotNil(spec)
        XCTAssertTrue(spec!.promptNeedles.contains("trust this folder"))
        XCTAssertTrue(spec!.promptNeedles.contains("Do you trust"))
        XCTAssertEqual(spec!.startedWithNoPromptNeedle, "? for shortcuts")
        XCTAssertEqual(spec!.settledBannerNeedle, "Claude")
    }

    // MARK: TrustPromptWatcher — the one loop both transports now share

    func testWatcherAcceptsOnPromptNeedle() {
        let spec = TrustPromptSpec(promptNeedles: ["trust this folder"],
                                   startedWithNoPromptNeedle: nil,
                                   settledBannerNeedle: "Claude")
        var pressed = false
        var reads = ["", "  Do you trust this folder …"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { pressed = true })
        XCTAssertTrue(pressed)
    }

    func testWatcherStopsOnNoPromptSentinelWithoutPressing() {
        let spec = TrustPromptSpec(promptNeedles: ["trust this folder"],
                                   startedWithNoPromptNeedle: "? for shortcuts",
                                   settledBannerNeedle: "Claude")
        var pressed = false
        var reads = ["Claude Code v2 — ? for shortcuts"]
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { pressed = true })
        XCTAssertFalse(pressed)
    }

    func testWatcherStopsAfterSettledThresholdWithNoPrompt() {
        let spec = TrustPromptSpec(promptNeedles: ["trust this folder"],
                                   startedWithNoPromptNeedle: nil,
                                   settledBannerNeedle: "Claude", settledThreshold: 2)
        var reads = ["Claude banner", "Claude banner", "trust this folder — too late"]
        var pressed = false
        TrustPromptWatcher.watch(spec: spec,
                                 read: { reads.isEmpty ? nil : reads.removeFirst() },
                                 press: { pressed = true })
        // Settled twice on the banner before a (late) prompt needle ever
        // showed up — the watcher must already have stood down.
        XCTAssertFalse(pressed)
        XCTAssertEqual(reads.count, 1, "watcher should have stopped, leaving the third read unconsumed")
    }

    // MARK: reviveCommand goes through the adapter now, not a second literal

    func testReviveCommandUsesAdapterResumeArguments() {
        let session = SessionDiscovery.Session(
            sessionId: "sess-1", cwd: "/tmp/x", transcriptPath: "/tmp/x.jsonl",
            title: nil, lastActivityAt: Date(), answered: true, activity: nil,
            liveness: .gone, revivable: true)
        XCTAssertEqual(session.reviveCommand?.arguments, ["--resume", "sess-1"])
        XCTAssertEqual(session.reviveCommand?.cwd, "/tmp/x")
    }
}
