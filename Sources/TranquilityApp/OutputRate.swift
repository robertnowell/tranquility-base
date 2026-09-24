import CoreAudio
import Foundation
import LiveKitWebRTC

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
final class OutputRateFollower {
    private let adm: LKRTCAudioDeviceModule
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "tb.output-rate")
    private var watching: AudioDeviceID = 0
    private var pending: DispatchWorkItem?
    private var lastSeen: Double = 0

    /// Bluetooth fires several property changes in a burst as it renegotiates.
    /// Acting on the first one rebuilds against a rate that is still moving.
    private let settleSeconds = 0.25

    init(adm: LKRTCAudioDeviceModule, log: @escaping @Sendable (String) -> Void) {
        self.adm = adm
        self.log = log
    }

    func start() {
        queue.async { [self] in
            watch(Self.defaultOutput())
            listenForDefaultOutputChanges()
        }
    }

    func stop() {
        queue.async { [self] in
            pending?.cancel()
            unwatch()
        }
    }

    // MARK: - the device we are following

    private func watch(_ device: AudioDeviceID) {
        guard device != 0, device != watching else { return }
        unwatch()
        watching = device
        lastSeen = Self.rate(of: device)
        var address = Self.rateAddress
        let me = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(device, &address, Self.rateChanged, me)
        log(String(format: "output rate: following device %u at %.0f Hz", device, lastSeen))
    }

    private func unwatch() {
        guard watching != 0 else { return }
        var address = Self.rateAddress
        AudioObjectRemovePropertyListener(
            watching, &address, Self.rateChanged, Unmanaged.passUnretained(self).toOpaque())
        watching = 0
    }

    /// The person can also change output mid-session, which is a different
    /// device with its own rate; follow that too.
    private func listenForDefaultOutputChanges() {
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address,
            { _, _, _, ctx in
                guard let ctx else { return noErr }
                let me = Unmanaged<OutputRateFollower>.fromOpaque(ctx).takeUnretainedValue()
                me.queue.async { me.changed(device: OutputRateFollower.defaultOutput()) }
                return noErr
            },
            Unmanaged.passUnretained(self).toOpaque())
    }

    private static let rateChanged: AudioObjectPropertyListenerProc = { _, _, _, ctx in
        guard let ctx else { return noErr }
        let me = Unmanaged<OutputRateFollower>.fromOpaque(ctx).takeUnretainedValue()
        me.queue.async { me.changed(device: me.watching) }
        return noErr
    }

    // MARK: - the response

    private func changed(device: AudioDeviceID) {
        if device != watching { watch(device) }
        let now = Self.rate(of: watching)
        guard now > 0 else { return }
        log(String(format: "output rate: %.0f -> %.0f Hz", lastSeen, now))
        lastSeen = now
        pending?.cancel()
        let work = DispatchWorkItem { [self] in rebuild() }
        pending = work
        queue.asyncAfter(deadline: .now() + settleSeconds, execute: work)
    }

    /// Re-initialise playout against the rate the device settled on. The module
    /// reads the device's format when playout is initialised and not again, so
    /// this is the only way to make it notice.
    private func rebuild() {
        let settled = Self.rate(of: watching)
        guard settled > 0 else { return }
        let stopped = adm.stopPlayout()
        let inited = adm.initPlayout()
        let started = adm.startPlayout()
        log(String(format: "output rate: settled at %.0f Hz; playout rebuilt"
                   + " (stop %ld, init %ld, start %ld, playing %@)",
                   settled, stopped, inited, started, adm.playing ? "yes" : "no"))
    }

    // MARK: - CoreAudio

    private static let rateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    static func defaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultOutputAddress
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func rate(of device: AudioDeviceID) -> Double {
        guard device != 0 else { return 0 }
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        var address = rateAddress
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }
}
