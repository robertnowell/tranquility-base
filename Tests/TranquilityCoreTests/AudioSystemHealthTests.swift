import CoreAudio
import Foundation
import Testing
@testable import TranquilityCore

/// The health monitor: which codes mean "not answering", that a slow call
/// is reported before it returns, and that only a change of direction is
/// news. No HAL: the monitor is fed by the calls it wraps.
struct AudioSystemHealthTests {

    @Test func machTimeoutCodesMeanTheDaemonDidNotAnswer() {
        #expect(AudioSystemHealth.isTimeout(0x10004003))
        #expect(AudioSystemHealth.isTimeout(0x10000004))
        #expect(!AudioSystemHealth.isTimeout(noErr))
        #expect(!AudioSystemHealth.isTimeout(OSStatus(kAudioHardwareBadObjectError)))
    }

    @Test func aSlowCallIsReportedBeforeItReturns() async throws {
        let health = AudioSystemHealth(stallThreshold: 0.1)
        let heard = Heard()
        health.subscribe { heard.append($0) }
        health.timed("slow") { Thread.sleep(forTimeInterval: 0.35) }
        // Reported during the call, not after it.
        #expect(heard.states.first?.isWedged == true)
        #expect(health.current.isWedged)
        // The next fast call is the daemon answering again.
        health.timed("fast") { }
        #expect(!health.current.isWedged)
        #expect(heard.states.map(\.isWedged) == [true, false])
    }

    @Test func aFastCallReportsNothing() {
        let health = AudioSystemHealth(stallThreshold: 0.1)
        let heard = Heard()
        health.subscribe { heard.append($0) }
        health.timed("fast") { }
        #expect(heard.states.isEmpty)
        #expect(!health.current.isWedged)
    }

    @Test func aTimeoutStatusIsAWedgeAndAnyAnswerClearsIt() {
        let health = AudioSystemHealth(stallThreshold: 5)
        let heard = Heard()
        health.subscribe { heard.append($0) }
        health.note(0x10004003, from: "x")
        #expect(health.current.isWedged)
        // A plain error is the daemon saying no, which is the daemon answering.
        health.note(OSStatus(kAudioHardwareBadObjectError), from: "x")
        #expect(!health.current.isWedged)
        #expect(heard.states.map(\.isWedged) == [true, false])
    }

    @Test func onlyAChangeOfDirectionIsNews() {
        let health = AudioSystemHealth(stallThreshold: 5)
        let heard = Heard()
        health.subscribe { heard.append($0) }
        health.note(0x10004003, from: "a")
        health.note(0x10000004, from: "b")
        health.note(0x10004003, from: "c")
        #expect(heard.states.count == 1)
        if case .wedged(let since) = health.current {
            // The first timestamp is kept; later timeouts do not move it.
            #expect(Date().timeIntervalSince(since) < 5)
        }
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [AudioSystemHealth.State] = []
        var states: [AudioSystemHealth.State] { lock.lock(); defer { lock.unlock() }; return list }
        func append(_ s: AudioSystemHealth.State) { lock.lock(); list.append(s); lock.unlock() }
    }
}
