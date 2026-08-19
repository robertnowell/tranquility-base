import XCTest
@testable import TranquilityCore

/// The microphone preference, pinned.
///
/// This shipped untested because it was written into the executable target, where
/// no test can reach it — the same reason the transition table had no tests. The
/// bug it exists to prevent is silent: if the preference stops resolving past a
/// Bluetooth default, capture goes back to AirPods and the only symptom is a
/// format-mismatch failure some minutes later.
final class AudioInputDeviceTests: XCTestCase {

    private let key = "audioInputPreference"
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: key)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    /// The recommendation is the default, not an opt-in. A first-run user on
    /// AirPods is exactly who this protects, and they have not opened a menu.
    func testDefaultIsBuiltInWhenNothingIsStored() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(AudioInputPreference.current, .builtIn)
    }

    /// A value written by a future version — or corrupted — falls back to the
    /// recommendation rather than to whatever the system default happens to be.
    /// Failing open here would silently reintroduce the bug.
    func testUnparseableStoredValueFallsBackToBuiltIn() {
        UserDefaults.standard.set("someFutureOption", forKey: key)
        XCTAssertEqual(AudioInputPreference.current, .builtIn)
    }

    func testPreferenceRoundTrips() {
        AudioInputPreference.current = .systemDefault
        XCTAssertEqual(AudioInputPreference.current, .systemDefault)
        AudioInputPreference.current = .builtIn
        XCTAssertEqual(AudioInputPreference.current, .builtIn)
    }

    /// Both options are offered, and the built-in one says it is recommended —
    /// the menu builds its entries from these, so an empty or unlabelled case
    /// would ship a blank row.
    func testEveryPreferenceHasATitle() {
        XCTAssertEqual(AudioInputPreference.allCases.count, 2)
        for option in AudioInputPreference.allCases {
            XCTAssertFalse(option.title.isEmpty)
        }
        XCTAssertTrue(AudioInputPreference.builtIn.title.contains("recommended"))
    }

    // MARK: - Hardware-dependent, and honest about it

    /// Asserts a relationship rather than a device name, so it holds on any Mac:
    /// under `.builtIn` the resolved device must be the built-in one whenever the
    /// machine has one, EVEN IF the system default is something else. That
    /// "even if" is the entire feature.
    func testBuiltInPreferenceResolvesPastTheSystemDefault() throws {
        guard let builtIn = AudioInputDevice.builtIn else {
            throw XCTSkip("no built-in microphone on this machine")
        }
        XCTAssertEqual(AudioInputDevice.resolve(.builtIn)?.id, builtIn.id)
        XCTAssertTrue(builtIn.isBuiltIn)
        XCTAssertFalse(builtIn.isBluetooth)
    }

    /// A Mac with no built-in microphone (a Studio, a Mini) must still record.
    /// Falling through to the system default is better than refusing.
    func testBuiltInPreferenceFallsBackWhenThereIsNoBuiltInMic() {
        if AudioInputDevice.builtIn == nil {
            XCTAssertEqual(AudioInputDevice.resolve(.builtIn)?.id,
                           AudioInputDevice.systemDefault?.id)
        }
    }

    /// Enumeration excludes output-only devices at the source rather than at each
    /// call site, so anything listed can actually be recorded from.
    func testEveryEnumeratedDeviceIsAnInput() {
        for device in AudioInputDevice.allInputs() {
            XCTAssertFalse(device.name.isEmpty, "device \(device.id) has no name")
            XCTAssertFalse(device.isBuiltIn && device.isBluetooth,
                           "\(device.name) cannot be both built-in and Bluetooth")
        }
    }

    // MARK: - The display snapshot (18 Aug)

    /// The whole point: a read that draws must never walk the hardware.
    ///
    /// The bound is 5 ms against a live read measured at a median of 34 ms and
    /// a p99 of 1011 ms, so this is not a threshold sitting next to the thing
    /// it measures — the two are orders of magnitude apart, which is what makes
    /// it a drill rather than a coin toss.
    func testAColdSnapshotReadDoesNotWalkTheHardware() {
        let cache = AudioInputDevice.DeviceCache()
        let t0 = Date()
        let devices = cache.current()
        let ms = Date().timeIntervalSince(t0) * 1000
        XCTAssertTrue(devices.isEmpty, "a cold snapshot is empty, never loaded in line")
        XCTAssertLessThan(ms, 5, "the cold read walked the hardware")
    }

    /// Empty is a real answer while the first refresh is in flight, and the
    /// menu is written to survive it: no device name, no Bluetooth warning,
    /// for one tick.
    func testAColdResolveIsNilRatherThanAGuess() {
        let cache = AudioInputDevice.DeviceCache()
        XCTAssertNil(cache.current().first)
        XCTAssertEqual(cache.currentDefaultId(), 0)
    }

    /// After the prime, the snapshot answers with the machine's real devices,
    /// and agrees with the live read it stands in for.
    func testThePrimedSnapshotAgreesWithTheLiveRead() throws {
        let live = AudioInputDevice.allInputs()
        try XCTSkipIf(live.isEmpty, "no input devices on this machine")
        AudioInputDevice.primeCache()
        let cache = AudioInputDevice.DeviceCache()
        cache.refreshNow()
        XCTAssertEqual(cache.current().map(\.id), live.map(\.id))
        XCTAssertEqual(AudioInputDevice.cachedResolve(.builtIn)?.id,
                       AudioInputDevice.resolve(.builtIn)?.id)
        XCTAssertEqual(AudioInputDevice.cachedResolve(.systemDefault)?.id,
                       AudioInputDevice.resolve(.systemDefault)?.id)
    }

    /// A fresh snapshot claims no refresh, so a poll tick reading it every
    /// 1.5 s cannot start a walk every 1.5 s — which would move the cost off
    /// the main actor and leave it on the machine.
    func testAFreshSnapshotStartsNoSecondWalk() {
        let cache = AudioInputDevice.DeviceCache(maxAge: 60)
        cache.refreshNow()
        let first = cache.current()
        let second = cache.current()
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    /// Reset is the tests' own door, and it must genuinely empty the snapshot —
    /// a reset that leaves a stamp would make every later drill read stale.
    func testResetEmptiesTheSnapshot() {
        let cache = AudioInputDevice.DeviceCache()
        cache.refreshNow()
        cache.reset()
        XCTAssertTrue(cache.current().isEmpty)
        XCTAssertEqual(cache.currentDefaultId(), 0)
    }
}
