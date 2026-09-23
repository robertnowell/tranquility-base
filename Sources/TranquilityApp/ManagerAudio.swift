import AVFoundation
import Foundation
import LiveKitWebRTC
import TranquilityCore

/// The app's own voice, played through the connection's audio engine so the
/// echo canceller subtracts it.
///
/// A canceller removes the audio its own renderer played, and nothing else. The
/// manager's voice arrives over the connection, is rendered by WebRTC, and is
/// cancelled. Every line the app reads aloud itself — an agent's announcement
/// in that session's voice — was rendered by `AVAudioPlayer`, a different
/// client of the same speakers, and was never in the reference. On 23 Sep the
/// microphone brought three of them back verbatim, ten seconds apart, and each
/// was judged as something the developer had said.
///
/// The fix is not to stop listening while the app talks. It is to give the app
/// no second renderer: `RTCAudioDeviceModuleTypeAudioEngine` hands this
/// delegate the live `AVAudioEngine`, and its `configureOutput` hook lets a
/// player node of ours join the graph that feeds `AVAudioOutputNode`. Measured
/// on this Mac, 23 Sep: the hook fires, the node attaches, and the same module
/// reports Apple's Voice Processing I/O as available and ACTIVE, where
/// `platformDefault` reports it unavailable and falls back to the software
/// canceller.
///
/// It also owns the capture device, because the two are the same object's
/// problem: `.audioEngine` refuses `trySetInputDevice` (returns false, and the
/// property reads empty), while the engine's own input unit takes `setDeviceID`
/// and lands on the built-in microphone — which is the policy
/// `AudioInputDevice.swift` exists to hold.
final class ManagerAudio: NSObject, LKRTCAudioDeviceModuleDelegate, SpokenAudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private let player = AVAudioPlayerNode()
    private var engine: AVAudioEngine?
    private var renderFormat: AVAudioFormat?
    private var attached = false
    private var startedAt: AVAudioTime?

    var onTrace: (@Sendable (String) -> Void)?
    private func trace(_ line: String) { onTrace?("manager audio: \(line)") }

    // MARK: - SpokenAudioSink

    var isReady: Bool {
        lock.withLock { attached && (engine?.isRunning ?? false) }
    }

    var played: TimeInterval {
        lock.withLock {
            guard let node = player.lastRenderTime, let t = player.playerTime(forNodeTime: node),
                  t.sampleRate > 0 else { return 0 }
            return Double(t.sampleTime) / t.sampleRate
        }
    }

    func play(_ data: Data) async throws {
        let (engine, format) = try lock.withLock { () -> (AVAudioEngine, AVAudioFormat) in
            guard attached, let live = self.engine, let format = renderFormat, live.isRunning else {
                throw ManagerAudioError.noEngine
            }
            return (live, format)
        }
        let buffer = try Self.decode(data, to: format)
        trace("playing \(String(format: "%.1f", Double(buffer.frameLength) / format.sampleRate))s through the engine")
        player.stop()
        player.play()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                done.resume()
            }
        }
        _ = engine
    }

    func stop() {
        player.stop()
    }

    // MARK: - decoding

    enum ManagerAudioError: Error { case noEngine, undecodable }

    /// ElevenLabs returns MP3 and the system voice returns PCM; both go through
    /// `AVAudioFile`, which needs a file, and then through a converter because
    /// the engine renders one channel at 48 kHz and neither source does.
    private static func decode(_ data: Data, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-manager-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ManagerAudioError.undecodable
        }
        try file.read(into: source)
        if file.processingFormat == format { return source }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw ManagerAudioError.undecodable
        }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ManagerAudioError.undecodable
        }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        guard out.frameLength > 0 else { throw ManagerAudioError.undecodable }
        return out
    }

    // MARK: - the capture device

    /// The built-in microphone by transport type — not by name, and never the
    /// system default, which is the AirPods and the failure
    /// `AudioInputDevice.swift` was written about.
    private static func builtInMicrophone() -> AudioDeviceID? {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var transport = UInt32(0)
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            var taddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var streams = UInt32(0)
            var saddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &streams) == noErr,
                  streams > 0 else { continue }
            return id
        }
        return nil
    }

    /// Before the engine starts, the input unit takes a device. Once it is
    /// running it does not (measured: the call returns and the id is unchanged),
    /// which is why this runs from `didCreateEngine` and `configureInput` and
    /// not from a convenient place afterwards.
    private func pinInput(_ engine: AVAudioEngine) {
        guard let want = Self.builtInMicrophone() else { trace("no built-in microphone"); return }
        let unit = engine.inputNode.auAudioUnit
        let before = unit.deviceID
        guard before != want else { return }
        do {
            try unit.setDeviceID(want)
            trace("capture device \(before) -> \(unit.deviceID)"
                  + (unit.deviceID == want ? "" : " (wanted \(want), NOT pinned)"))
        } catch {
            trace("capture device \(before), setDeviceID(\(want)) refused: \(error)")
        }
    }

    // MARK: - LKRTCAudioDeviceModuleDelegate

    func audioDeviceModule(_ m: LKRTCAudioDeviceModule,
                           didReceiveSpeechActivityEvent e: LKRTCSpeechActivityEvent) {}

    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int {
        pinInput(engine)
        return 0
    }

    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool,
                           isVoiceProcessingEnabled: Bool) -> Int {
        trace("engine enabling: playout=\(isPlayoutEnabled) recording=\(isRecordingEnabled) "
              + "voice processing=\(isVoiceProcessingEnabled)")
        return 0
    }

    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }

    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        lock.withLock { attached = false }
        return 0
    }

    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        lock.withLock { attached = false }
        return 0
    }

    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        player.stop()
        lock.withLock { attached = false; self.engine = nil; renderFormat = nil }
        return 0
    }

    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureInputFromSource src: AVAudioNode?, toDestination dst: AVAudioNode,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        pinInput(engine)
        return 0
    }

    /// The whole point. `src` is the connection's own output mixer and `dst` is
    /// the device; connecting a player node of ours to the same destination puts
    /// the app's voice in the graph the canceller references.
    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureOutputFromSource src: AVAudioNode, toDestination dst: AVAudioNode?,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        let destination = dst ?? engine.mainMixerNode
        if player.engine !== engine {
            player.engine?.detach(player)
            engine.attach(player)
        }
        engine.connect(player, to: destination, format: format)
        engine.connect(src, to: destination, format: format)
        lock.withLock {
            self.engine = engine
            renderFormat = format
            attached = true
        }
        trace("the app's voice now renders through the connection's engine (\(format))")
        return 0
    }

    func audioDeviceModuleDidUpdateDevices(_ m: LKRTCAudioDeviceModule) {}
}
