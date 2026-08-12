import Foundation
import Testing
@testable import TranquilityCore

/// The mic lifecycle table. Every accepted row, every refused row, and the
/// two properties that motivated the machine: stale generations cannot act,
/// and the wedge is entered on evidence and left only on evidence.
struct MicMachineTests {

    // MARK: - The happy path

    @Test func coldPreparesThenOpensThenCaptures() {
        var m = MicMachine()
        #expect(m.state == .cold)
        #expect(m.submit(.unitPrepared).accepted)
        #expect(m.state == .warm)
        let open = m.submit(.openRequested)
        #expect(open.accepted)
        #expect(m.state == .opening(generation: 1))
        #expect(m.submit(.firstBuffer(generation: 1)).accepted)
        #expect(m.state == .capturing(generation: 1))
        #expect(m.submit(.captureEnded).accepted)
        #expect(m.state == .warm)
    }

    @Test func secondCaptureReusesTheWarmUnit() {
        var m = MicMachine()
        m.submit(.unitPrepared)
        m.submit(.openRequested); m.submit(.firstBuffer(generation: 1)); m.submit(.captureEnded)
        let again = m.submit(.openRequested)
        #expect(again.accepted)
        #expect(m.state == .opening(generation: 2))
    }

    // MARK: - Generation staleness (the abandon-mid-open race, closed by type)

    @Test func staleFirstBufferIsRefused() {
        var m = MicMachine()
        m.submit(.unitPrepared)
        m.submit(.openRequested)               // generation 1
        m.submit(.captureEnded)                // abandoned before audio arrived
        m.submit(.openRequested)               // generation 2
        // A late verdict for the abandoned generation must not act.
        #expect(!m.submit(.firstBuffer(generation: 1)).accepted)
        #expect(m.state == .opening(generation: 2))
        // The current generation's verdict still lands.
        #expect(m.submit(.firstBuffer(generation: 2)).accepted)
    }

    @Test func staleFailureCannotWedgeANewerOpen() {
        var m = MicMachine()
        m.submit(.unitPrepared)
        m.submit(.openRequested)               // generation 1
        m.submit(.captureEnded)
        m.submit(.openRequested)               // generation 2
        #expect(!m.submit(.openFailed(generation: 1)).accepted)
        #expect(m.consecutiveFailures == 0)
    }

    @Test func verdictsAfterCaptureEndAreRefused() {
        var m = MicMachine()
        m.submit(.unitPrepared)
        m.submit(.openRequested); m.submit(.firstBuffer(generation: 1)); m.submit(.captureEnded)
        #expect(!m.submit(.firstBuffer(generation: 1)).accepted)
        #expect(!m.submit(.openFailed(generation: 1)).accepted)
        #expect(m.state == .warm)
    }

    // MARK: - Refusals that keep the table honest

    @Test func openRefusedUnlessWarm() {
        var m = MicMachine()
        #expect(!m.submit(.openRequested).accepted)          // cold
        m.submit(.unitPrepared)
        m.submit(.openRequested)
        #expect(!m.submit(.openRequested).accepted)          // already opening
        m.submit(.firstBuffer(generation: 1))
        #expect(!m.submit(.openRequested).accepted)          // already capturing
    }

    @Test func prepareRefusedMidCapture() {
        var m = MicMachine()
        m.submit(.unitPrepared)
        m.submit(.openRequested)
        #expect(!m.submit(.unitPrepared).accepted)
        m.submit(.firstBuffer(generation: 1))
        #expect(!m.submit(.unitPrepared).accepted)
    }

    @Test func discardForgetsWarmth() {
        var m = MicMachine()
        m.submit(.unitPrepared)
        #expect(m.submit(.unitDiscarded).accepted)
        #expect(m.state == .cold)
        #expect(!m.submit(.openRequested).accepted)
    }

    // MARK: - The wedge

    @Test func consecutiveFailuresWedge() {
        var m = MicMachine()
        m.submit(.unitPrepared)
        m.submit(.openRequested)
        let first = m.submit(.openFailed(generation: 1))
        #expect(first.accepted)
        #expect(first.effect == nil)
        #expect(m.state == .warm)                             // one failure = retry allowed
        m.submit(.openRequested)
        let second = m.submit(.openFailed(generation: 2))
        #expect(second.accepted)
        #expect(second.effect == .enterWedge)                 // threshold crossed
        #expect(m.state == .wedged(failures: 2))
    }

    @Test func aGoodOpenResetsTheFailureCount() {
        var m = MicMachine()
        m.submit(.unitPrepared)
        m.submit(.openRequested)
        m.submit(.openFailed(generation: 1))                  // 1 failure
        m.submit(.openRequested)
        m.submit(.firstBuffer(generation: 2))                 // success resets
        m.submit(.captureEnded)
        m.submit(.openRequested)
        let fail = m.submit(.openFailed(generation: 3))
        #expect(fail.effect == nil)                           // count restarted at 1
        #expect(m.state == .warm)
    }

    @Test func wedgeRefusesOpensDiscardsAndPrepares() {
        var m = MicMachine()
        m.submit(.unitPrepared)
        m.submit(.openRequested); m.submit(.openFailed(generation: 1))
        m.submit(.openRequested); m.submit(.openFailed(generation: 2))
        #expect(m.state == .wedged(failures: 2))
        #expect(!m.submit(.openRequested).accepted)           // no per-press retries
        #expect(!m.submit(.unitDiscarded).accepted)           // failure count survives
        #expect(!m.submit(.unitPrepared).accepted)            // rebuild alone is not proof
        #expect(!m.state.allowsAutoArm)                       // hands-free stays silent
    }

    @Test func healedLeavesTheWedgeOnEvidence() {
        var m = MicMachine()
        m.submit(.unitPrepared)
        m.submit(.openRequested); m.submit(.openFailed(generation: 1))
        m.submit(.openRequested); m.submit(.openFailed(generation: 2))
        #expect(m.submit(.healed).accepted)
        #expect(m.state == .warm)
        #expect(m.consecutiveFailures == 0)
        // And healed means nothing anywhere else.
        #expect(!m.submit(.healed).accepted)
    }

    @Test func autoArmAllowedEverywhereExceptWedged() {
        #expect(MicState.cold.allowsAutoArm)
        #expect(MicState.warm.allowsAutoArm)
        #expect(MicState.opening(generation: 1).allowsAutoArm)
        #expect(MicState.capturing(generation: 1).allowsAutoArm)
        #expect(!MicState.wedged(failures: 2).allowsAutoArm)
    }
}
