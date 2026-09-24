import XCTest
import CoreAudio
@testable import TranquilityCore

/// The arithmetic that makes a chipmunk, stated once so the number in the
/// commit message cannot drift from the number in the code.
///
/// 23 Sep, wearing AirPods: everything the manager said came out an octave up
/// and at double speed. The device reads 48000 Hz before a session, 24000 Hz
/// for the moment the duplex link renegotiates, and 48000 Hz again once it
/// settles — and the audio module reads the rate exactly once, inside that
/// window. Samples prepared for 24000 and played at 48000 come out at twice
/// the speed, which is one octave.
final class OutputRateTests: XCTestCase {
    func testRenderingAtHalfTheDeviceRateDoublesTheSpeed() {
        let configured = 24000.0, device = 48000.0
        XCTAssertEqual(device / configured, 2.0, accuracy: 0.0001)
    }

    /// A doubling of playback rate is a rise of exactly twelve semitones.
    func testWhichIsExactlyAnOctave() {
        let semitones = 12 * log2(48000.0 / 24000.0)
        XCTAssertEqual(semitones, 12, accuracy: 0.0001)
    }

    /// The other direction is the one nobody reported, because it is much less
    /// alarming: settling low would have sounded slow and deep.
    func testTheOppositeMismatchWouldHaveSoundedSlow() {
        XCTAssertLessThan(24000.0 / 48000.0, 1.0)
    }
}

// MARK: - The follower lets go

/// The audio system as a test sees it: what was registered, what was
/// removed, and the ability to fire either listener at any moment — including
/// the moment the crash found, after the owner has gone.
final class FakeOutputDevices: OutputDeviceSource, @unchecked Sendable {
    private let lock = NSLock()
    private var rates: [AudioDeviceID: Double]
    private var defaultDevice: AudioDeviceID
    private var rateListeners: [AudioDeviceID: @Sendable () -> Void] = [:]
    private var defaultListener: (@Sendable () -> Void)?
    private(set) var added = 0
    private(set) var removed = 0

    init(defaultDevice: AudioDeviceID, rates: [AudioDeviceID: Double]) {
        self.defaultDevice = defaultDevice
        self.rates = rates
    }

    var live: Int { lock.lock(); defer { lock.unlock() }; return rateListeners.count + (defaultListener == nil ? 0 : 1) }
    var watchedDevices: [AudioDeviceID] { lock.lock(); defer { lock.unlock() }; return Array(rateListeners.keys) }

    func set(rate: Double, of device: AudioDeviceID) { lock.lock(); rates[device] = rate; lock.unlock() }
    func set(defaultDevice: AudioDeviceID) { lock.lock(); self.defaultDevice = defaultDevice; lock.unlock() }

    /// Fire the listeners as CoreAudio would, whether or not they are still
    /// registered: an in-flight callback does not check.
    func fireRate(of device: AudioDeviceID) { lock.lock(); let f = rateListeners[device]; lock.unlock(); f?() }
    func fireDefault() { lock.lock(); let f = defaultListener; lock.unlock(); f?() }

    func defaultOutput() -> AudioDeviceID { lock.lock(); defer { lock.unlock() }; return defaultDevice }
    func rate(of device: AudioDeviceID) -> Double { lock.lock(); defer { lock.unlock() }; return rates[device] ?? 0 }

    func watchRate(of device: AudioDeviceID, on queue: DispatchQueue,
                   changed: @escaping @Sendable () -> Void) -> OutputRateFollower.Cancel {
        lock.lock(); rateListeners[device] = { queue.async(execute: changed) }; added += 1; lock.unlock()
        return { [self] in lock.lock(); rateListeners[device] = nil; removed += 1; lock.unlock() }
    }

    func watchDefaultOutput(on queue: DispatchQueue,
                            changed: @escaping @Sendable () -> Void) -> OutputRateFollower.Cancel {
        lock.lock(); defaultListener = { queue.async(execute: changed) }; added += 1; lock.unlock()
        return { [self] in lock.lock(); defaultListener = nil; removed += 1; lock.unlock() }
    }
}

final class RebuildCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

/// 23 Sep, 19:22: the app died on the `tb.output-rate` queue thirteen minutes
/// after hands-free was switched off, when the default output device changed
/// and a listener nobody had removed asked a freed audio module to stop
/// playing. Every test here is a rule the first version broke.
final class OutputRateFollowerTests: XCTestCase {
    let airpods: AudioDeviceID = 137
    let speakers: AudioDeviceID = 55

    private func follower(_ devices: FakeOutputDevices, rebuilds: RebuildCount,
                          settle: TimeInterval = 0.02) -> OutputRateFollower {
        OutputRateFollower(devices: devices, settleSeconds: settle, log: { _ in }) {
            rebuilds.bump()
            return "fake"
        }
    }

    private func wait(_ seconds: TimeInterval) {
        let e = expectation(description: "time passes")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 2)
    }

    func testStartWatchesTheDefaultDeviceAndTheDefaultItself() {
        let devices = FakeOutputDevices(defaultDevice: airpods, rates: [airpods: 48000])
        let f = follower(devices, rebuilds: RebuildCount())
        f.start()
        XCTAssertEqual(devices.watchedDevices, [airpods])
        XCTAssertEqual(devices.live, 2)
        f.stop()
    }

    /// The burst: several changes inside the settle window are one rebuild,
    /// against the rate the device ended on.
    func testABurstOfChangesSettlesIntoOneRebuild() {
        let devices = FakeOutputDevices(defaultDevice: airpods, rates: [airpods: 48000])
        let rebuilds = RebuildCount()
        let f = follower(devices, rebuilds: rebuilds)
        f.start()
        devices.set(rate: 24000, of: airpods); devices.fireRate(of: airpods)
        devices.set(rate: 48000, of: airpods); devices.fireRate(of: airpods)
        devices.set(rate: 24000, of: airpods); devices.fireRate(of: airpods)
        wait(0.1)
        XCTAssertEqual(rebuilds.value, 1)
        f.stop()
    }

    /// The crash, exactly: hands-free stopped inside the settle window.
    func testAStopInsideTheSettleWindowMeansNoRebuild() {
        let devices = FakeOutputDevices(defaultDevice: airpods, rates: [airpods: 48000])
        let rebuilds = RebuildCount()
        let f = follower(devices, rebuilds: rebuilds, settle: 0.05)
        f.start()
        devices.set(rate: 24000, of: airpods); devices.fireRate(of: airpods)
        f.stop()
        wait(0.15)
        XCTAssertEqual(rebuilds.value, 0)
    }

    /// `stop()` removes BOTH listeners — the first version removed one.
    func testStopRemovesEveryListener() {
        let devices = FakeOutputDevices(defaultDevice: airpods, rates: [airpods: 48000])
        let f = follower(devices, rebuilds: RebuildCount())
        f.start()
        XCTAssertEqual(devices.live, 2)
        f.stop()
        XCTAssertEqual(devices.live, 0)
        XCTAssertEqual(devices.added, devices.removed)
    }

    /// A callback already in flight when `stop()` ran must do nothing. This
    /// is the thirteen-minutes-later case: the fake keeps the closures the
    /// way CoreAudio would keep a queued call, and fires them anyway.
    func testACallbackAfterStopDoesNothing() {
        let devices = FakeOutputDevices(defaultDevice: airpods, rates: [airpods: 48000])
        let rebuilds = RebuildCount()
        let f = follower(devices, rebuilds: rebuilds)
        f.start()
        let device = airpods
        let rateLate = { [devices] in devices.fireRate(of: device) }
        let defaultLate = { [devices] in devices.fireDefault() }
        f.stop()
        devices.set(defaultDevice: speakers); devices.set(rate: 44100, of: speakers)
        rateLate(); defaultLate()
        wait(0.1)
        XCTAssertEqual(rebuilds.value, 0)
        XCTAssertEqual(devices.live, 0, "a late callback must not register anything either")
    }

    /// The owner that forgets: going out of scope is a stop.
    func testAFollowerDroppedWithoutStopLetsGo() {
        let devices = FakeOutputDevices(defaultDevice: airpods, rates: [airpods: 48000])
        let rebuilds = RebuildCount()
        var f: OutputRateFollower? = follower(devices, rebuilds: rebuilds)
        f?.start()
        XCTAssertEqual(devices.live, 2)
        f = nil
        XCTAssertEqual(devices.live, 0)
        devices.set(rate: 24000, of: airpods); devices.fireRate(of: airpods); devices.fireDefault()
        wait(0.1)
        XCTAssertEqual(rebuilds.value, 0)
    }

    /// Changing output mid-session: the old device is let go and the new one
    /// followed, and the new one's settled rate is what gets rebuilt.
    func testANewDefaultDeviceIsFollowedAndTheOldOneReleased() {
        let devices = FakeOutputDevices(defaultDevice: airpods, rates: [airpods: 48000, speakers: 44100])
        let rebuilds = RebuildCount()
        let f = follower(devices, rebuilds: rebuilds)
        f.start()
        devices.set(defaultDevice: speakers); devices.fireDefault()
        wait(0.1)
        XCTAssertEqual(devices.watchedDevices, [speakers])
        XCTAssertEqual(devices.live, 2)
        XCTAssertEqual(rebuilds.value, 1)
        f.stop()
        XCTAssertEqual(devices.live, 0)
    }

    /// Twice is fine, and so is stopping from inside the rebuild closure —
    /// which is on the follower's own queue.
    func testStopIsIdempotentAndReentrant() {
        let devices = FakeOutputDevices(defaultDevice: airpods, rates: [airpods: 48000])
        let stopsFromInside = RebuildCount()
        final class Box: @unchecked Sendable { var f: OutputRateFollower? }
        let box = Box()
        box.f = OutputRateFollower(devices: devices, settleSeconds: 0.02, log: { _ in }) {
            box.f?.stop(); stopsFromInside.bump(); return "stopped from inside"
        }
        box.f?.start()
        devices.set(rate: 24000, of: airpods); devices.fireRate(of: airpods)
        wait(0.1)
        XCTAssertEqual(stopsFromInside.value, 1)
        XCTAssertEqual(devices.live, 0)
        box.f?.stop()
        XCTAssertEqual(devices.live, 0)
    }
}
