import XCTest
@testable import TranquilityCore

/// The 24 Oct 2026 leak pass: what a card, a pane or a notice names on the
/// user's Mac does not leave it. Each test checks both sides: the app's own
/// words still arrive, the user's names for things do not.
final class TelemetryLeakTests: XCTestCase {

    private func strings(_ props: [String: TrackValue]) -> String {
        props.values.map(\.tokenString).joined(separator: " ").lowercased()
    }

    func testANoticePhraseKeepsTheAppsWordsAndDropsTheTabLabel() {
        XCTAssertEqual(Track.phrase("Couldn't type into Acme Secret Launch: tab gone."), .token("couldn_t_type_into"))
        XCTAssertEqual(Track.phrase("Install id copied: ad8e1234"), .token("install_id_copied"))
        XCTAssertEqual(Track.phrase("Mic off"), .token("mic_off"))
    }

    func testANoticeFailureLeavesAsItsPhraseAndOtherKindsKeepTheirReason() {
        let notice = Failures.telemetryReason(kind: .notice, reason: "Couldn't type into Acme Secret Launch: gone")
        XCTAssertFalse(notice.tokenString.contains("secret"))
        XCTAssertEqual(notice, .token("couldn_t_type_into"))
        let other = Failures.telemetryReason(kind: .deliveryFailed, reason: "dispatch failed: tmux exited 1")
        XCTAssertEqual(other.tokenString, "dispatch failed: tmux exited 1", "app and system errors still arrive")
    }

    func testAPaneScreenLeavesAsFactsAndNeverItsWords() {
        let screen = "Do you trust the files in /Users/someone/acme-secret-plans?\n\n 1. Yes\n 2. No"
        let facts = PaneScreen.facts(screen)
        XCTAssertEqual(facts["screen_prompt"], .token("trust"))
        XCTAssertEqual(facts["screen_matched"], .bool(true))
        XCTAssertEqual(facts["screen_lines"], .int(3))
        XCTAssertFalse(strings(facts).contains("secret"))
        XCTAssertTrue(facts.values.allSatisfy { if case .prose = $0 { return false }; return true })
        XCTAssertEqual(PaneScreen.facts("")["screen_prompt"], .token("none"))
        XCTAssertEqual(PaneScreen.facts("bash-5.2$ ")["screen_matched"], .bool(false))
    }

    func testTurningUsageOnClearsAPersistedOptOutAndStartsTheSDK() {
        typealias C = TelemetryConsent
        XCTAssertEqual(C.actions(enabled: true, started: false, optedOut: false), [.start, .optIn])
        XCTAssertEqual(C.actions(enabled: true, started: true, optedOut: true), [.optIn],
                       "a persisted opt-out is cleared when the toggle is on")
        XCTAssertEqual(C.actions(enabled: true, started: true, optedOut: false), [])
        XCTAssertEqual(C.actions(enabled: false, started: true, optedOut: false), [.optOut])
        XCTAssertEqual(C.actions(enabled: false, started: true, optedOut: true), [])
        XCTAssertEqual(C.actions(enabled: false, started: false, optedOut: false), [], "off never starts the SDK")
    }
}
