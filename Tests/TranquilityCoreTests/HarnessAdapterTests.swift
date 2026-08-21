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
                                 press: { pressed = true },
                                 pollInterval: 0.001)
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
                                 press: { pressed = true },
                                 pollInterval: 0.001)
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
                                 press: { pressed = true },
                                 pollInterval: 0.001)
        // Settled twice on the banner before a (late) prompt needle ever
        // showed up — the watcher must already have stood down.
        XCTAssertFalse(pressed)
        XCTAssertEqual(reads.count, 1, "watcher should have stopped, leaving the third read unconsumed")
    }

    // MARK: reviveCommand goes through the adapter now, not a second literal

    // MARK: empty resumeArguments must refuse, never emit broken AppleScript

    func testEmptyResumeArgumentsRefusesRatherThanBuildingBrokenScript() {
        struct SilentAdapter: HarnessAdapter {
            let id = "silent"
            func resumeArguments(sessionId: String) -> [String] { [] }
            var trustPrompt: TrustPromptSpec? { nil }
            var capabilities: HarnessCapabilities {
                HarnessCapabilities(echoesPaste: false, promptGlyph: "", queuesInputMidTurn: false,
                                    registersWithLiveness: false, hasHooks: false)
            }
        }
        let result = SessionLauncher.resume(sessionId: "x", directory: NSTemporaryDirectory(),
                                            command: "true", acceptTrustPrompt: false,
                                            adapter: SilentAdapter())
        guard case .failure(let error) = result else {
            return XCTFail("an adapter with no resume arguments must refuse, not run AppleScript")
        }
        XCTAssertTrue(error.message.contains("silent"))
    }

    // MARK: capabilities parity — until TmuxTransport reads these values live,
    // a test is what stops them silently drifting from what it hardcodes
    // (M2 gate finding: 5 capability fields had zero consumers).

    func testClaudeCodeEchoesPasteMatchesWhatTmuxTransportAssumes() {
        // TmuxTransport.swift's landing check is unconditional on the belief
        // that "every target echoes" — true for Claude Code (measured 19
        // Aug) and for the raw-mode test harness (which writes its own
        // echo). This pins the Claude Code half of that belief to the
        // adapter's declared capability, so the day they diverge, THIS
        // fails instead of a delivery silently misbehaving.
        XCTAssertTrue(ClaudeCodeAdapter().capabilities.echoesPaste,
                      "TmuxTransport's landing check assumes every target echoes; " +
                      "wiring it to read this value per-target is M3+ scope")
    }

    func testReviveCommandUsesAdapterResumeArguments() {
        let session = SessionDiscovery.Session(
            sessionId: "sess-1", cwd: "/tmp/x", transcriptPath: "/tmp/x.jsonl",
            title: nil, lastActivityAt: Date(), answered: true, activity: nil,
            liveness: .gone, revivable: true)
        XCTAssertEqual(session.reviveCommand?.arguments, ["--resume", "sess-1"])
        XCTAssertEqual(session.reviveCommand?.cwd, "/tmp/x")
    }
}
