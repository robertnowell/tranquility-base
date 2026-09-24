import CoreAudio
import Foundation

/// Follow the output device's sample rate, because it changes underneath us.
///
/// Wearing AirPods, everything the manager said came out an octave up and at
/// double speed, for the whole session, while the same audio outside hands-free
/// was fine. The reason is not the headphones and not the voice: it is that
/// CoreAudio tells you one rate and then changes its mind.
///
/// Apple's own developer forum describes exactly this (thread 770232, answered
/// by an Apple engineer): a read of the AirPods' stream format returns 48000,
/// and shortly after CoreAudio sends a `kAudioDevicePropertyStreamFormat`
/// change notification correcting it to 24000. An application that does not
/// handle the notification keeps the stale number and its audio plays
/// stretched. The engineer's reply is the whole fix — "Were you able to resolve
/// the issue by handling the notification?"
///
/// Measured here, three runs, with `tools/webrtc-spike`:
///
///     before connecting          output device 137 at 48000 Hz
///     the instant playout starts output device 137 at 24000 Hz
///     14s, 22s, 30s, 38s         output device 137 at 48000 Hz
///
/// A Bluetooth headset renegotiates its link when a duplex path opens — it
/// cannot carry full-quality output and a voice uplink at once — so it passes
/// through the low rate and settles back. WebRTC's macOS audio module
/// initialises its playout inside that window and never looks again; WebRTC's
/// own contributors say on the project mailing list that the desktop modules
/// "are rather old and might not be up-to-date when it comes to device
/// handling". Twenty-four thousand samples a second rendered into a device
/// running at forty-eight is exactly twice the speed and an octave up.
///
/// So: watch the rate, and when it changes, make the module initialise its
/// playout again against what the device is actually doing now. Three
/// independent projects hitting this converged on the same shape — listen,
/// let the burst settle, rebuild — and on the same warning against the
/// alternative. Setting `kAudioDevicePropertyNominalSampleRate` back is a
/// device-wide write that every other application on that device feels, and
/// the Bluetooth stack will simply change it again.
///
/// ## The follower has to let go
///
/// The first version of this class crashed the app twenty minutes after it
/// shipped (23 Sep, 19:22, `EXC_BAD_ACCESS` on the `tb.output-rate` queue).
/// Hands-free had been switched off a second and a half after it started —
/// inside the AirPods' low-rate window — and the peer, its WebRTC factory and
/// the audio module's worker thread were all gone. The follower was not: it
/// had registered two CoreAudio listeners with an unretained pointer to
/// itself, `stop()` removed one of them, nothing removed the other, and
/// nothing ran on the way out of scope. Thirteen minutes later the default
/// output device changed, CoreAudio called the surviving listener, the
/// follower scheduled a rebuild, and the rebuild told a module whose worker
/// thread had been freed to stop playing. The log shows none of this, because
/// the log line went through the peer, and the peer was already nil.
///
/// So the rules this class now keeps, each of which the crash broke:
///   - Listeners are blocks that hold the follower weakly, on the follower's
///     own queue. There is no unretained pointer for CoreAudio to call after
///     the object is gone.
///   - `stop()` is synchronous. When it returns, every listener is removed,
///     the settle timer is cancelled, and the rebuild closure will never run
///     again — so the owner can tear down what the closure touches.
///   - Going out of scope is a stop. `deinit` removes the listeners too, for
///     the owner that forgets.
///   - The audio system is behind `OutputDeviceSource`, so all of the above is
///     asserted by a test, with a fake that records what was registered and
///     what was removed, rather than by a second crash.
public final class OutputRateFollower: @unchecked Sendable {
    public typealias Cancel = @Sendable () -> Void

    private let devices: OutputDeviceSource
    private let log: @Sendable (String) -> Void
    /// Re-initialise playout against the settled rate; returns a few words
    /// for the log ("stop 0, init 0, start 0, playing yes").
    private let rebuild: @Sendable () -> String
    private let queue = DispatchQueue(label: "tb.output-rate")
    private static let queueKey = DispatchSpecificKey<Void>()

    private var watching: AudioDeviceID = 0
    private var cancelRate: Cancel?
    private var cancelDefault: Cancel?
    private var pending: DispatchWorkItem?
    private var lastSeen: Double = 0
    private var stopped = false

    /// Bluetooth fires several property changes in a burst as it renegotiates.
    /// Acting on the first one rebuilds against a rate that is still moving.
    private let settle: TimeInterval

    public init(devices: OutputDeviceSource = CoreAudioOutput(),
                settleSeconds: TimeInterval = 0.25,
                log: @escaping @Sendable (String) -> Void,
                rebuild: @escaping @Sendable () -> String) {
        self.devices = devices
        self.settle = settleSeconds
        self.log = log
        self.rebuild = rebuild
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit { letGo() }

    public func start() {
        onQueue {
            guard !stopped, cancelDefault == nil else { return }
            watch(devices.defaultOutput())
            // The person can also change output mid-session, which is a
            // different device with its own rate; follow that too.
            cancelDefault = devices.watchDefaultOutput(on: queue) { [weak self] in
                guard let self else { return }
                self.changed(device: self.devices.defaultOutput())
            }
        }
    }

    /// Synchronous: on return nothing registered by this follower is still
    /// live and `rebuild` will not be called again. Safe to call twice, and
    /// from the follower's own queue.
    public func stop() {
        onQueue { letGo() }
    }

    // MARK: - the device we are following

    private func watch(_ device: AudioDeviceID) {
        guard device != 0, device != watching else { return }
        cancelRate?()
        cancelRate = nil
        watching = device
        lastSeen = devices.rate(of: device)
        cancelRate = devices.watchRate(of: device, on: queue) { [weak self] in
            guard let self else { return }
            self.changed(device: self.watching)
        }
        log(String(format: "output rate: following device %u at %.0f Hz", device, lastSeen))
    }

    private func letGo() {
        stopped = true
        pending?.cancel()
        pending = nil
        cancelRate?()
        cancelRate = nil
        watching = 0
        cancelDefault?()
        cancelDefault = nil
    }

    // MARK: - the response

    private func changed(device: AudioDeviceID) {
        guard !stopped else { return }
        if device != watching { watch(device) }
        let now = devices.rate(of: watching)
        guard now > 0 else { return }
        log(String(format: "output rate: %.0f -> %.0f Hz", lastSeen, now))
        lastSeen = now
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled() }
        pending = work
        queue.asyncAfter(deadline: .now() + settle, execute: work)
    }

    /// Re-initialise playout against the rate the device settled on. The module
    /// reads the device's format when playout is initialised and not again, so
    /// this is the only way to make it notice.
    private func settled() {
        guard !stopped else { return }
        let rate = devices.rate(of: watching)
        guard rate > 0 else { return }
        let detail = rebuild()
        log(String(format: "output rate: settled at %.0f Hz; playout rebuilt (%@)", rate, detail))
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    // MARK: - reading the device without a follower

    public static func defaultOutput() -> AudioDeviceID { CoreAudioOutput().defaultOutput() }
    public static func rate(of device: AudioDeviceID) -> Double { CoreAudioOutput().rate(of: device) }
}

/// The audio system as the follower sees it. CoreAudio in the app; a fake in
/// the tests, which is the only way to prove what happens after `stop()`.
public protocol OutputDeviceSource: Sendable {
    func defaultOutput() -> AudioDeviceID
    func rate(of device: AudioDeviceID) -> Double
    /// Call `changed` on `queue` whenever the device's nominal rate changes.
    /// The returned closure removes the listener.
    func watchRate(of device: AudioDeviceID, on queue: DispatchQueue,
                   changed: @escaping @Sendable () -> Void) -> OutputRateFollower.Cancel
    /// Call `changed` on `queue` whenever the default output device changes.
    func watchDefaultOutput(on queue: DispatchQueue,
                            changed: @escaping @Sendable () -> Void) -> OutputRateFollower.Cancel
}

public struct CoreAudioOutput: OutputDeviceSource {
    public init() {}

    private static let rateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public func defaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.defaultOutputAddress
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    public func rate(of device: AudioDeviceID) -> Double {
        guard device != 0 else { return 0 }
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        var address = Self.rateAddress
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }

    public func watchRate(of device: AudioDeviceID, on queue: DispatchQueue,
                          changed: @escaping @Sendable () -> Void) -> OutputRateFollower.Cancel {
        Self.listen(to: device, for: Self.rateAddress, on: queue, changed: changed)
    }

    public func watchDefaultOutput(on queue: DispatchQueue,
                                   changed: @escaping @Sendable () -> Void) -> OutputRateFollower.Cancel {
        Self.listen(to: AudioObjectID(kAudioObjectSystemObject), for: Self.defaultOutputAddress,
                    on: queue, changed: changed)
    }

    /// A block listener, the same shape `Recorder` and `AudioSystemWatch` use:
    /// nothing unretained crosses into CoreAudio, and removal is one call
    /// with the same block.
    private static func listen(to object: AudioObjectID, for address: AudioObjectPropertyAddress,
                               on queue: DispatchQueue,
                               changed: @escaping @Sendable () -> Void) -> OutputRateFollower.Cancel {
        let registration = Registration(object: object, address: address, queue: queue) { _, _ in changed() }
        registration.add()
        return { registration.remove() }
    }

    /// The block is not Sendable as far as the compiler knows; it is ours,
    /// captures only a Sendable closure, and is only ever handed back to
    /// CoreAudio for removal.
    private final class Registration: @unchecked Sendable {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock

        init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
             block: @escaping AudioObjectPropertyListenerBlock) {
            self.object = object
            self.address = address
            self.queue = queue
            self.block = block
        }

        func add() {
            var a = address
            AudioObjectAddPropertyListenerBlock(object, &a, queue, block)
        }

        func remove() {
            var a = address
            AudioObjectRemovePropertyListenerBlock(object, &a, queue, block)
        }
    }
}
