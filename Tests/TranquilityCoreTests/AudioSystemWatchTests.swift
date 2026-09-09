import Foundation
import Testing
@testable import TranquilityCore

/// The system watch: the hold table, the wait it drives, and the device
/// cache it invalidates. All without a HAL, because the one property that
/// matters, "an idle app makes no HAL call", cannot be shown on hardware
/// that is never idle.
struct AudioSystemWatchTests {

    // MARK: - The hold table

    @Test func nothingMovedMeansNoWait() {
        let hold = AudioSystemWatch.Hold(settle: 3, cap: 6)
        let now = Date()
        #expect(hold.remaining(lastMutation: nil, now: now, waitingSince: now) == 0)
    }

    @Test func waitsOutTheSettleAfterAMutation() {
        let hold = AudioSystemWatch.Hold(settle: 3, cap: 6)
        let now = Date()
        let oneSecondAgo = now.addingTimeInterval(-1)
        #expect(abs(hold.remaining(lastMutation: oneSecondAgo, now: now, waitingSince: now) - 2) < 0.001)
    }

    @Test func anOldMutationIsAlreadySettled() {
        let hold = AudioSystemWatch.Hold(settle: 3, cap: 6)
        let now = Date()
        #expect(hold.remaining(lastMutation: now.addingTimeInterval(-10), now: now, waitingSince: now) == 0)
    }

    /// A flapping device (AirPods Pro, 199 route changes in two hours on
    /// 28 Aug) keeps refreshing the mutation. The cap is what turns an
    /// endless hold into a bounded one.
    @Test func theCapBoundsAFlappingDevice() {
        let hold = AudioSystemWatch.Hold(settle: 3, cap: 6)
        let began = Date()
        let now = began.addingTimeInterval(5.5)
        let justNow = now.addingTimeInterval(-0.1)
        #expect(abs(hold.remaining(lastMutation: justNow, now: now, waitingSince: began) - 0.5) < 0.001)
        let past = began.addingTimeInterval(6.2)
        #expect(hold.remaining(lastMutation: past, now: past, waitingSince: began) == 0)
    }

    // MARK: - The wait

    @Test func settleReturnsAtOnceWhenNothingMoved() async {
        let watch = AudioSystemWatch(installing: false)
        let began = Date()
        await watch.settle(AudioSystemWatch.Hold(settle: 1, cap: 2))
        #expect(Date().timeIntervalSince(began) < 0.2)
    }

    @Test func settleHoldsAfterAMutationAndSaysSo() async {
        let watch = AudioSystemWatch(installing: false)
        watch.noteMutation(.defaultOutput)
        let lines = Lines()
        let began = Date()
        await watch.settle(AudioSystemWatch.Hold(settle: 0.3, cap: 1)) { lines.append($0) }
        let elapsed = Date().timeIntervalSince(began)
        #expect(elapsed >= 0.25 && elapsed < 1.0)
        #expect(lines.all.first?.contains("speakers held") == true)
        #expect(lines.all.first?.contains("defaultOutput") == true)
        #expect(lines.all.last?.contains("released") == true)
    }

    @Test func settleIsCappedWhileMutationsKeepArriving() async {
        let watch = AudioSystemWatch(installing: false)
        watch.noteMutation(.devices)
        let flapper = Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                watch.noteMutation(.devices)
            }
        }
        let began = Date()
        await watch.settle(AudioSystemWatch.Hold(settle: 0.3, cap: 0.6))
        flapper.cancel()
        let elapsed = Date().timeIntervalSince(began)
        #expect(elapsed >= 0.5 && elapsed < 1.5)
    }

    @Test func subscribersHearEveryMutation() {
        let watch = AudioSystemWatch(installing: false)
        let heard = Heard()
        watch.subscribe { kind in heard.append(kind) }
        watch.noteMutation(.serviceRestarted)
        watch.noteMutation(.devices)
        #expect(heard.kinds == [.serviceRestarted, .devices])
        #expect(watch.lastMutation?.kind == .devices)
    }

    // MARK: - The device cache

    /// An idle app makes no HAL call: the loader runs once to fill the
    /// snapshot and then not again until somebody invalidates it, however
    /// many times the menu asks.
    @Test func cacheLoadsOnceUntilInvalidated() async throws {
        let counter = LoadCounter()
        let cache = AudioInputDevice.DeviceCache(maxAge: 300) {
            counter.bump()
            return ([], 0)
        }
        _ = cache.current()
        try await Task.sleep(nanoseconds: 100_000_000)
        for _ in 0..<50 { _ = cache.current() }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(counter.count == 1)
        cache.invalidate()
        _ = cache.current()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(counter.count == 2)
    }

    /// The safety age still exists, against a notification the HAL never
    /// sent, and it is minutes, not seconds.
    @Test func cacheSafetyAgeIsMinutes() async throws {
        let counter = LoadCounter()
        let cache = AudioInputDevice.DeviceCache(maxAge: 0.05) {
            counter.bump()
            return ([], 0)
        }
        _ = cache.current()
        try await Task.sleep(nanoseconds: 120_000_000)
        _ = cache.current()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(counter.count == 2)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
        func append(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [AudioSystemWatch.Mutation] = []
        var kinds: [AudioSystemWatch.Mutation] { lock.lock(); defer { lock.unlock() }; return list }
        func append(_ k: AudioSystemWatch.Mutation) { lock.lock(); list.append(k); lock.unlock() }
    }

    private final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func bump() { lock.lock(); n += 1; lock.unlock() }
    }
}
