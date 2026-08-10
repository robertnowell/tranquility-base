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
    /// Every audio device the HAL knows about, input or output.
    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr
        else { return 0 }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return Int(UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels })
    }

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

    // MARK: - In use by anyone (the courtesy check's first question)

    /// Whether ANY process on the machine currently has this device running —
    /// us, Zoom, a screen recorder, system dictation.
    ///
    /// This is the signal `InterruptGate.mutedApps` could never be. That list is
    /// matched against the FRONTMOST app only, so the overwhelmingly common
    /// shape of the failure — a call in the background while you read your
    /// terminal — matches nothing and the app talks over you. It is also
    /// unmaintainable by construction: it can only ever name the conferencing
    /// apps somebody thought of.
    ///
    /// Crucially this does NOT open the microphone. It asks the HAL a question
    /// about the device, so it costs no permission, lights no recording
    /// indicator, and puts the app nowhere in Control Center. That is what makes
    /// it safe to ask before every announcement, and what makes it the cheap
    /// gate that keeps the expensive one (actually listening) rare.
    public static func isInUse(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    // MARK: - Who is using the audio hardware (macOS 14.2+)

    /// One process the HAL knows about, and whether it is currently running
    /// audio in either direction.
    public struct AudioProcess: Sendable, Equatable {
        public let pid: pid_t
        public let bundleID: String?
        public let usingInput: Bool
        public let usingOutput: Bool
        /// Best available name: the bundle id if the HAL knows it, else the
        /// process name from the kernel, else the bare pid.
        public var name: String {
            if let bundleID, !bundleID.isEmpty { return bundleID }
            return ProcessProbe.name(of: Int(pid)) ?? "pid \(pid)"
        }
    }

    /// Every process currently running audio, named.
    ///
    /// `kAudioHardwarePropertyProcessObjectList` arrived in macOS 14.2 alongside
    /// the Core Audio process-tap API. Before it there was no supported way to
    /// ask WHICH app holds the microphone — only whether the device was running
    /// — so "something is listening" was the most any app could say.
    ///
    /// Returns an empty array on anything older, which callers must treat as "we
    /// cannot tell" rather than "nobody is using it": the device-level
    /// `isInUse` check stays the authority on whether to speak.
    public static func audioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            let input = processFlag(id, kAudioProcessPropertyIsRunningInput)
            let output = processFlag(id, kAudioProcessPropertyIsRunningOutput)
            guard input || output else { return nil }
            return AudioProcess(pid: processPID(id) ?? -1,
                                bundleID: processBundleID(id),
                                usingInput: input, usingOutput: output)
        }
    }

    private static func processFlag(_ id: AudioObjectID,
                                    _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func processPID(_ id: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func processBundleID(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// Bundle ids that hold audio without a human being on the other end.
    ///
    /// Measured 10 Aug, sampling every three seconds: `com.apple.CoreSpeech`
    /// (Siri / "Hey Siri" listening) and `com.apple.Sound-Settings.extension`
    /// (the Sound pane drawing its input-level meter) both held the microphone
    /// continuously on an otherwise idle machine. A device-level "is the mic in
    /// use" check cannot tell those from a phone call, so a gate built on it
    /// would have vetoed every announcement for as long as System Settings was
    /// open — going permanently silent for a reason the user cannot see, which
    /// is worse than the interruption it is preventing.
    ///
    /// Deliberately short, and deliberately not a general "system process"
    /// filter: anything not on this list gets the benefit of the doubt and
    /// blocks the hail. Adding to it should require the same evidence the
    /// original entries have — an observation of it holding audio with nobody
    /// speaking.
    static let alwaysOnAudioClients: Set<String> = [
        "com.apple.CoreSpeech",
        "com.apple.Sound-Settings.extension",
        "com.apple.controlcenter",
    ]

    /// Somebody ELSE is using the audio hardware — not us, not a system daemon
    /// that always is. Returns who, for the log and the panel's one-line notice.
    ///
    /// This is the whole courtesy check, after the room-listening version was
    /// deleted. It costs one HAL round-trip, opens nothing, needs no permission,
    /// and answers the question the listening version was trying to infer from
    /// a microphone: is a human on the other end of some audio right now.
    ///
    /// `ourBundleID` is excluded because our own TTS shows up here the moment we
    /// speak — an app that refused to announce because it was announcing would
    /// deadlock itself on the first hail.
    ///
    /// Nil when the process list is unavailable (before macOS 14.2) — callers
    /// must fall back to the device-level flag rather than reading nil as "the
    /// coast is clear".
    public static func otherAppUsingAudio(ourBundleID: String?) -> String? {
        let processes = audioProcesses()
        guard !processes.isEmpty else { return nil }
        return processes.first { p in
            guard p.usingInput || p.usingOutput else { return false }
            guard let bundle = p.bundleID, !bundle.isEmpty else { return false }
            if bundle == ourBundleID { return false }
            return !alwaysOnAudioClients.contains(bundle)
        }?.name
    }

    /// Whether the HAL can name audio clients at all on this machine.
    public static var canNameAudioClients: Bool { !audioProcesses().isEmpty }

    /// Every device with at least one OUTPUT channel.
    ///
    /// Same enumeration as `allInputs`, other scope. Kept here rather than in a
    /// new type because it is the same HAL round-trip against the same device
    /// list, and splitting it would duplicate `allDeviceIDs` for no gain.
    public static func allOutputs() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard outputChannelCount(id) > 0, let name = name(id) else { return nil }
            let transport = transportType(id)
            return Device(id: id, name: name,
                          isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                          isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                              || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }

    /// Is anything PLAYING right now — a call, a video, music, another app's
    /// notification chime?
    ///
    /// The same question as `anyInputInUse`, asked of the other direction, and
    /// worth asking for the same reason: talking over a podcast is the same
    /// discourtesy as talking over a person, and neither needs a microphone to
    /// detect. Free, no permission, opens nothing.
    ///
    /// Excludes aggregate and virtual devices by name where we can tell — a
    /// loopback device that is always "running" would pin this to true forever
    /// and silence every announcement, which is the failure mode to watch for.
    public static func anyOutputInUse() -> Bool {
        allOutputs().contains { isInUse($0.id) }
    }

    /// Is any input device in use? Asks every input, not just the resolved one.
    ///
    /// Deliberately broader than `resolve()`: a Zoom call is happening on the
    /// device Zoom chose, which on a machine with AirPods connected is very
    /// often not the built-in mic this app prefers. Asking only about our own
    /// device would answer the wrong question and miss the call entirely.
    ///
    /// Fails toward "in use" being unobservable rather than false — an
    /// enumeration that returns nothing yields false, which degrades to today's
    /// behaviour (speak) rather than to permanent silence.
    public static func anyInputInUse() -> Bool {
        allInputs().contains { isInUse($0.id) }
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
