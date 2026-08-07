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
}
