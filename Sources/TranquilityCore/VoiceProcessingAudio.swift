import AVFoundation
import AudioToolbox
import Foundation

/// The microphone and the manager's voice on one voice-processing unit, so
/// the manager can be interrupted.
///
/// Today the manager cannot be cut off mid-sentence. Its voice plays on one
/// unit and the microphone is captured on another, so the only defence
/// against it transcribing itself is a gate in the bot that feeds the
/// transcriber silence while it speaks — which means that while it speaks,
/// nobody can say "stop". macOS already solves the real problem:
/// `kAudioUnitSubType_VoiceProcessingIO` subtracts what it renders from what
/// it captures, adapting to the room, the way every conferencing app does.
/// Nothing here tunes it and there is nothing to tune. What this file has to
/// get right is the wiring: the manager's voice must be rendered *through
/// this unit*, because a canceller removes what it renders and nothing else.
///
/// Two facts measured on 22 Sep (tools/aec-probe):
///   - the unit will not initialize pinned to an input-only device (-10875);
///     it wants one device carrying both directions, so TN2091's pinning,
///     which `CaptureUnit` depends on, does not transfer.
///   - unpinned it takes a device of its own choosing and runs at that
///     device's rate with one capture channel.
///
/// Because it chooses, this is a preference and not a replacement: when it
/// will not start, hands-free falls back to `ManagerMicrophone` plus
/// `PCMPlayer` and the bot's gate, and says so in the log.
public final class VoiceProcessingAudio: ManagerAudioSource {
    private var unit: AudioUnit?
    private var converter: StreamingPCM16Converter?
    private var captureFormat: AVAudioFormat?
    private var onPCM16: (@Sendable (Data) -> Void)?
    /// The manager's voice, waiting to be rendered, at the unit's rate.
    private let outgoing = Outgoing()
    private var rate: Double = 48000
    private var captureChannels = 1

    /// The player half. Handing this to `ManagerSocket` is what puts the
    /// manager's voice through the canceller instead of past it.
    public private(set) lazy var player: PCMPlayer = VoiceProcessingPlayer(self)

    public init() {}

    /// Whether this Mac will give us a voice-processing unit at all, asked
    /// before hands-free commits to one. Instantiating and initializing is
    /// the only honest test: the failure we have already seen (-10875) does
    /// not surface until initialize.
    public static func isAvailable() -> Bool {
        let probe = VoiceProcessingAudio()
        do { try probe.start { _ in }; probe.stop(); return true }
        catch { return false }
    }

    // MARK: - the voice waiting to play

    final class Outgoing: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var head = 0

        func append(_ new: [Float]) {
            lock.lock()
            if head > 0 { samples.removeFirst(head); head = 0 }
            samples.append(contentsOf: new)
            lock.unlock()
        }

        /// Drop everything unplayed: an interruption, or the end of a line.
        func clear() {
            lock.lock(); samples.removeAll(keepingCapacity: true); head = 0; lock.unlock()
        }

        /// Fill `count` samples, padding with silence when the voice has run out.
        func take(_ count: Int, into out: UnsafeMutablePointer<Float>, stride: Int) {
            lock.lock()
            for i in 0..<count {
                if head < samples.count { out[i * stride] = samples[head]; head += 1 }
                else { out[i * stride] = 0 }
            }
            if head > 48000 { samples.removeFirst(head); head = 0 }
            lock.unlock()
        }
    }

    // MARK: - ManagerAudioSource

    public func start(onPCM16: @escaping @Sendable (Data) -> Void) throws {
        self.onPCM16 = onPCM16
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw VoiceProcessingError.unavailable("no voice-processing component")
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "instantiate")
        self.unit = unit

        var on: UInt32 = 1
        try check(AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &on, UInt32(MemoryLayout<UInt32>.size)), "enable capture")
        try check(AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &on, UInt32(MemoryLayout<UInt32>.size)), "enable render")
        // Pin only to a device that carries both directions; anything else is
        // refused at initialize, and the unit's own choice is better than a
        // failure. The fallback path is what handles a choice we dislike.
        if let both = Self.deviceCarryingBothDirections() {
            var pinned = both
            _ = AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &pinned, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        var capture = AURenderCallbackStruct(inputProc: { ref, flags, stamp, bus, frames, _ in
            Unmanaged<VoiceProcessingAudio>.fromOpaque(ref).takeUnretainedValue()
                .captured(flags, stamp, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0, &capture,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "capture callback")

        var render = AURenderCallbackStruct(inputProc: { ref, _, _, _, frames, data in
            Unmanaged<VoiceProcessingAudio>.fromOpaque(ref).takeUnretainedValue().render(frames, data)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit!, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0, &render,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "render callback")

        try check(AudioUnitInitialize(unit!), "initialize")

        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit!, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &hardware, &size), "capture format")
        rate = hardware.mSampleRate
        captureChannels = Int(hardware.mChannelsPerFrame)
        captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                      channels: AVAudioChannelCount(captureChannels), interleaved: false)
        converter = captureFormat.flatMap { StreamingPCM16Converter(from: $0) }
        try check(AudioOutputUnitStart(unit!), "start")
    }

    public func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        converter = nil
        outgoing.clear()
    }

    /// The device to pin to, when one device carries the microphone and the
    /// speaker both. Otherwise nil, and the unit chooses.
    static func deviceCarryingBothDirections() -> AudioDeviceID? {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var input = AudioDeviceID(0)
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &input) == noErr
        else { return nil }
        return channels(input, kAudioObjectPropertyScopeOutput) > 0 ? input : nil
    }

    static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, data) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - the two callbacks

    fileprivate func enqueue(_ pcm16: Data, sourceRate: Double) {
        let frames = pcm16.count / 2
        guard frames > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        pcm16.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { mono[i] = Float(src[i]) / 32768 }
        }
        outgoing.append(sourceRate == rate ? mono : Self.resample(mono, from: sourceRate, to: rate))
    }

    fileprivate func flushOutgoing() { outgoing.clear() }

    /// Linear resampling, which is enough for speech going out to a speaker
    /// and keeps the render callback free of an AVAudioConverter.
    static func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, to > 0, !input.isEmpty else { return input }
        let ratio = to / from
        let count = Int(Double(input.count) * ratio)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let position = Double(i) / ratio
            let low = Int(position)
            let high = min(low + 1, input.count - 1)
            let t = Float(position - Double(low))
            out[i] = input[low] * (1 - t) + input[high] * t
        }
        return out
    }

    private func render(_ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let data else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(data)
        for buffer in list {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            outgoing.take(Int(frames), into: out, stride: channels)
            // Interleaved stereo: the same voice in both ears.
            if channels > 1 {
                for frame in 0..<Int(frames) {
                    let value = out[frame * channels]
                    for c in 1..<channels { out[frame * channels + c] = value }
                }
            }
        }
        return noErr
    }

    private func captured(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                          _ stamp: UnsafePointer<AudioTimeStamp>,
                          _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, let format = captureFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, stamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        if let data = converter?.convert(buffer), !data.isEmpty { onPCM16?(data) }
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw VoiceProcessingError.unavailable("\(what) failed: \(status)") }
    }
}

public enum VoiceProcessingError: Error, Equatable {
    case unavailable(String)
}

/// The manager's voice, rendered by the unit that is cancelling it.
/// `PCMPlayer`'s surface exactly, so `ManagerSocket` cannot tell them apart.
public final class VoiceProcessingPlayer: PCMPlayer {
    private weak var audio: VoiceProcessingAudio?
    init(_ audio: VoiceProcessingAudio) {
        self.audio = audio
        super.init()
    }
    public override func play(_ pcm16: Data) { audio?.enqueue(pcm16, sourceRate: 24_000) }
    public override func flush() { audio?.flushOutgoing() }
    public override func stop() { audio?.flushOutgoing() }
}
