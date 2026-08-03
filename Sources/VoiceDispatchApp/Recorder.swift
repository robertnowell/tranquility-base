import AVFoundation
import Foundation
import VoiceDispatchCore

/// Microphone capture for push-to-talk.
///
/// Buffers converted PCM16 in memory while the key is held and flushes once on
/// release, **before** anything touches the network. Per-chunk write-ahead was
/// considered and rejected: it only buys the crash-mid-utterance case, and the
/// failures that actually happen are network and API ones, which a single flush at
/// key-up already covers. That is a deliberate line, not an oversight.
public final class Recorder: @unchecked Sendable {
    public enum RecorderError: Error, Sendable {
        case microphoneDenied
        case engineFailed(String)
        case nothingRecorded
    }

    private let engine = AVAudioEngine()
    private let sampleRate: Double
    private var buffer = Data()
    private let lock = NSLock()
    private var running = false

    /// Live input level, for a waveform or an orb pulse.
    public private(set) var level: Float = 0

    public init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
    }

    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public static func microphoneAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Only prompts when the status is undetermined — macOS never re-prompts after a
    /// denial, so the UI has to send the user to System Settings instead.
    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public func start() throws {
        guard Self.microphoneAuthorized() else { throw RecorderError.microphoneDenied }
        lock.lock()
        guard !running else { lock.unlock(); return }
        buffer.removeAll(keepingCapacity: true)
        running = true
        lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] pcmBuffer, _ in
            guard let self else { return }
            if let converted = BuddyPCM16Converter.pcm16Data(
                from: pcmBuffer, targetSampleRate: self.sampleRate) {
                self.lock.lock()
                self.buffer.append(converted)
                self.lock.unlock()
            }
            self.level = Self.rms(of: pcmBuffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock(); running = false; lock.unlock()
            throw RecorderError.engineFailed("\(error)")
        }
    }

    /// Stop capturing and hand back everything recorded. The caller persists it
    /// before doing anything else.
    @discardableResult
    public func stop() throws -> Data {
        lock.lock()
        guard running else { lock.unlock(); throw RecorderError.nothingRecorded }
        running = false
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level = 0

        lock.lock()
        let captured = buffer
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        guard captured.count > 1600 else { throw RecorderError.nothingRecorded }  // <50ms
        return captured
    }

    /// Abandon without returning audio — used when a press is cancelled before the
    /// engine ever produced anything.
    public func abandon() {
        lock.lock()
        running = false
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level = 0
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
    }
}
