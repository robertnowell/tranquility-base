import AVFoundation
import CoreAudio
import Foundation

/// Which microphone capture binds to, and why it is not simply "whatever the
/// system default is".
///
/// The system default is the wrong default FOR THIS APP, and the reason is
/// specific to an app that both speaks and listens. AirPods — the default input
/// whenever they are connected — cannot run a high-quality output stream and a
/// microphone at the same time. Opening the mic drops them into HFP voice mode
/// (24kHz on this hardware, 16kHz on older), which degrades the announcement you
/// are replying TO, mid-sentence. `Recorder.start` says it plainly: "Replying
/// while the announcement is still playing is the normal case." On AirPods, the
/// normal case is the case that wrecks the voice the app just paid to generate.
///
/// It also breaks the plumbing. The rate flip lands while the engine is STOPPED,
/// so nothing renegotiates, and the next mic open installs a tap with a cached
/// format the hardware no longer has: `Failed to create tap due to format
/// mismatch` — every voice input on this machine dead from 15:12 to 15:13 on
/// 07 Aug, and identically on 05 Aug in the other direction (cached 24000
/// against a device at 48000).
///
/// A built-in microphone never re-rates. So the default is the built-in mic and
/// the system default becomes a CHOICE, which is also what the one shipping
/// competitor in this category concluded: Wispr Flow marks the built-in mic
/// "recommended" and warns on both AirPods and auto-detect.
public enum AudioInputPreference: String, CaseIterable {
    /// The machine's own microphone. Default, and the recommendation.
    case builtIn
    /// Follow System Settings › Sound › Input, whatever it happens to be.
    case systemDefault

    public var title: String {
        switch self {
        case .builtIn: return "Built-in mic (recommended)"
        case .systemDefault: return "System default"
        }
    }

    private static let key = "audioInputPreference"

    /// Built-in unless the user has said otherwise. A stored value that no
    /// longer parses falls back to the recommendation rather than to nothing.
    public static var current: AudioInputPreference {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(AudioInputPreference.init(rawValue:)) ?? .builtIn
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Thin CoreAudio reads. AVAudioEngine has no device vocabulary on macOS — it
/// binds one device for input and output and offers no way to ask what that is —
/// so device identity has to come from the HAL directly.
public enum AudioInputDevice {
    public struct Device {
        public var id: AudioDeviceID
        public var name: String
        public var isBuiltIn: Bool
        public var isBluetooth: Bool
    }

    /// Every device with at least one input channel. Output-only devices are
    /// excluded here rather than at each call site.
    public static func allInputs() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }
            let transport = transportType(id)
            return Device(
                id: id,
                name: name(id) ?? "Unknown input",
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }

    public static var systemDefault: Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
            id != 0 else { return nil }
        return allInputs().first { $0.id == id }
    }

    public static var builtIn: Device? { allInputs().first(where: \.isBuiltIn) }

    /// The device capture should bind to, or nil to let AVAudioEngine pick.
    ///
    /// Nil is a real answer, not a failure: a Mac with no built-in microphone
    /// (a Studio, a Mini) under the built-in preference has nothing to bind, and
    /// falling through to the engine's own choice is better than refusing to
    /// record. The mismatch defence does not depend on this — a fresh engine
    /// re-reads the hardware whatever device it lands on.
    public static func resolve(_ preference: AudioInputPreference = .current) -> Device? {
        switch preference {
        case .builtIn: return builtIn ?? systemDefault
        case .systemDefault: return systemDefault
        }
    }

    // MARK: - The display snapshot

    /// The same answer as `resolve`, from a snapshot at most 15 seconds old,
    /// refreshed off the calling thread. **For display only.**
    ///
    /// Measured 18 Aug, sampling the menu's own two `resolve` calls every 500 ms
    /// for ninety seconds on a machine with six input devices and AirPods Pro
    /// connected:
    ///
    ///     median 34.5 ms · p90 431 ms · p99 1011 ms · max 2081 ms
    ///     62 of 136 samples over 50 ms
    ///
    /// A tight loop had said 5 to 9 ms, and a tight loop is the wrong
    /// instrument: back to back, the HAL is warm and the round trip is nearly
    /// free. Spaced the way a poll tick spaces them, every call pays
    /// `coreaudiod` in full — six devices, four property reads each, roughly
    /// fifty IPC round trips per rebuild.
    ///
    /// `rebuildMenu()` runs on the 1.5 s tick, on the main actor. Two seconds
    /// there is a frozen app, and the poll loop's own comment already records
    /// what else it costs: "which also risks the CGEvent tap timing out, and a
    /// timed-out tap is dropped keystrokes."
    ///
    /// Stale is the right trade HERE and nowhere else. A menu naming the device
    /// you plugged in fifteen seconds ago is a menu; capture binding to a device
    /// that left fifteen seconds ago is a failed recording. So every call site
    /// that OPENS something keeps `resolve`, and only the ones that DRAW use
    /// this.
    public static func cachedResolve(_ preference: AudioInputPreference = .current) -> Device? {
        let devices = deviceCache.current()
        switch preference {
        case .builtIn:
            return devices.first(where: \.isBuiltIn) ?? devices.first { $0.id == cachedDefaultId }
        case .systemDefault:
            return devices.first { $0.id == cachedDefaultId }
        }
    }

    /// Fill the snapshot before anything draws, so the first menu names a real
    /// device instead of blanking for one tick. Call it off the main thread.
    public static func primeCache() { deviceCache.refreshNow() }

    private static let deviceCache = DeviceCache()
    private static var cachedDefaultId: AudioDeviceID { deviceCache.currentDefaultId() }

    /// Stale-while-revalidate with a single in-flight refresh, copied in shape
    /// from `SystemVoiceCatalog.RowsCache` because that pattern has already been
    /// proved here on exactly this problem: every reader gets the previous
    /// snapshot immediately, nobody ever waits on the loader, and the lock is
    /// held only across the assignments.
    final class DeviceCache: @unchecked Sendable {
        private let lock = NSLock()
        private let maxAge: TimeInterval
        private var devices: [Device] = []
        private var defaultId = AudioDeviceID(0)
        private var stamp: Date?
        private var refreshing = false

        init(maxAge: TimeInterval = 15) { self.maxAge = maxAge }

        func current() -> [Device] {
            lock.lock()
            let snapshot = devices
            let fresh = stamp.map { Date().timeIntervalSince($0) <= maxAge } ?? false
            let claimed = !fresh && !refreshing
            if claimed { refreshing = true }
            lock.unlock()
            if claimed {
                DispatchQueue.global(qos: .utility).async { [self] in
                    let loaded = AudioInputDevice.allInputs()
                    let id = AudioInputDevice.systemDefaultId()
                    lock.lock()
                    devices = loaded; defaultId = id; stamp = Date(); refreshing = false
                    lock.unlock()
                }
            }
            return snapshot
        }

        func currentDefaultId() -> AudioDeviceID {
            lock.lock(); defer { lock.unlock() }
            return defaultId
        }

        /// Synchronous, for the launch prime. The only caller that may block.
        func refreshNow() {
            let loaded = AudioInputDevice.allInputs()
            let id = AudioInputDevice.systemDefaultId()
            lock.lock()
            devices = loaded; defaultId = id; stamp = Date(); refreshing = false
            lock.unlock()
        }

        /// Tests need a cache that has never been filled.
        func reset() {
            lock.lock()
            devices = []; defaultId = 0; stamp = nil; refreshing = false
            lock.unlock()
        }
    }

    /// The default input's id alone — one property read, without the walk that
    /// `systemDefault` does to turn it into a `Device`.
    static func systemDefaultId() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return 0 }
        return id
    }

    // MARK: - Property reads

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr
        else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr
        else { return 0 }
        return transport
    }

    private static func name(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Via Unmanaged, which is a plain pointer: taking a raw pointer to a bare
        // CFString variable hands CoreAudio the address of a managed reference.
        // kAudioObjectPropertyName returns +1, so the retain is taken, not borrowed.
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfName) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, UnsafeMutableRawPointer($0))
        }
        guard status == noErr, let cfName else { return nil }
        return cfName.takeRetainedValue() as String
    }
}
