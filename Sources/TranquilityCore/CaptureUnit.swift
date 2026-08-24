import AVFoundation
import AudioToolbox
import Foundation

/// A raw AUHAL input unit pinned to one physical device.
///
/// This exists because AVAudioEngine cannot capture on macOS without first
/// binding the system default input: accessing `engine.inputNode` — the only
/// way to reach the unit you would configure — creates a
/// `CADefaultDeviceAggregate` wrapping the default devices before any app
/// code can intervene. Measured on this machine 12 Aug 2026 (probe with no
/// prepare/start/tap: `Creating DefaultDeviceAggregate → fetched default
/// input device, ID = 144` — the AirPods HFP mic), which is what dragged the
/// AirPods into SCO on every open and produced the day's wedges. Research
/// record: deep-research/2026-08-12-tb-mic-capture-stack-decision.
///
/// TN2091's sequence, which never queries the default device: instantiate
/// `kAudioUnitSubType_HALOutput` → enable input IO / disable output IO →
/// set `kAudioOutputUnitProperty_CurrentDevice` to the chosen device →
/// initialize. OBS ships exactly this shape on macOS.
///
/// The unit is built once and kept initialized (warm); a capture is
/// `AudioOutputUnitStart`/`Stop` on the prepared unit. Handler delivery
/// matches what the old engine tap provided — an `AVAudioPCMBuffer` in
/// Float32 deinterleaved at the hardware rate — so the conversion, append,
/// write-ahead and metering pipeline downstream is unchanged.
final class CaptureUnit {
    enum CaptureUnitError: Error {
        case componentNotFound
        case osStatus(String, OSStatus)
    }

    private var unit: AudioUnit?
    /// The device this unit is pinned to — never the default, by construction.
    let deviceID: AudioDeviceID
    /// The format buffers are delivered in (Float32 deinterleaved, hardware
    /// rate). Exposed so the owner can log what the tap really carries.
    private(set) var clientFormat: AVAudioFormat!

    /// Called on the CoreAudio render thread for every delivered buffer.
    /// The handler must be realtime-tolerable: the old engine tap did its
    /// conversion inline on the tap thread, so the contract is unchanged.
    private let handler: (AVAudioPCMBuffer) -> Void

    /// Reused across render calls — one allocation at build time, none on
    /// the render thread. Safe because AUHAL delivers input serially.
    private var renderBuffer: AVAudioPCMBuffer!
    private static let maxFrames: UInt32 = 4096

    init(deviceID: AudioDeviceID, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.deviceID = deviceID
        self.handler = handler
        try build()
    }

    deinit { dispose() }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CaptureUnitError.osStatus(what, status) }
    }

    private func build() throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CaptureUnitError.componentNotFound
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(component, &au), "instantiate")
        guard let au else { throw CaptureUnitError.componentNotFound }
        unit = au

        // Input on, output off — BEFORE the device is set (TN2091's order).
        var one: UInt32 = 1
        var zero: UInt32 = 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &one,
                                       UInt32(MemoryLayout<UInt32>.size)), "enable input IO")
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &zero,
                                       UInt32(MemoryLayout<UInt32>.size)), "disable output IO")

        // The one line the whole redesign exists for: the device is OURS,
        // stated explicitly, before initialization — the default is never
        // consulted, so the AirPods aggregate is never created.
        var device = deviceID
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &device,
                                       UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")

        // Hardware side of bus 1 tells us the device's native rate/channels;
        // the client side is what AudioUnitRender hands us. Float32
        // deinterleaved at the hardware rate, capped at stereo — the same
        // shape the engine tap delivered, so downstream code cannot tell
        // the capture stack changed.
        var hwFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 1, &hwFormat, &size), "read hw format")
        guard hwFormat.mSampleRate > 0 else {
            throw CaptureUnitError.osStatus("hw format invalid (rate 0)", -1)
        }
        let channels = min(max(hwFormat.mChannelsPerFrame, 1), 2)
        guard let client = AVAudioFormat(standardFormatWithSampleRate: hwFormat.mSampleRate,
                                         channels: AVAudioChannelCount(channels)) else {
            throw CaptureUnitError.osStatus("client format", -1)
        }
        clientFormat = client
        var clientASBD = client.streamDescription.pointee
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &clientASBD,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "set client format")

        var frames = Self.maxFrames
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
                                       kAudioUnitScope_Global, 0, &frames,
                                       UInt32(MemoryLayout<UInt32>.size)), "max frames")

        guard let buffer = AVAudioPCMBuffer(pcmFormat: client, frameCapacity: Self.maxFrames)
        else { throw CaptureUnitError.osStatus("render buffer", -1) }
        renderBuffer = buffer

        var callback = AURenderCallbackStruct(
            inputProc: captureUnitInputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "set input callback")

        try check(AudioUnitInitialize(au), "initialize")
    }

    /// Start IO. On a warm (initialized) unit this is the entire per-press
    /// hardware cost.
    func start() throws {
        guard let unit else { throw CaptureUnitError.componentNotFound }
        try check(AudioOutputUnitStart(unit), "start")
    }

    /// Stop IO. The unit stays initialized (warm) for the next press.
    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
    }

    /// Full teardown. After this the instance is unusable — build a new one.
    func dispose() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    fileprivate func render(_ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
                            _ inBusNumber: UInt32,
                            _ inNumberFrames: UInt32) -> OSStatus {
        guard let unit, let buffer = renderBuffer,
              inNumberFrames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = inNumberFrames
        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber,
                                     inNumberFrames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        handler(buffer)
        return noErr
    }
}

/// C-convention trampoline: AUHAL cannot call a Swift closure directly.
private func captureUnitInputProc(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    Unmanaged<CaptureUnit>.fromOpaque(inRefCon).takeUnretainedValue()
        .render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}
