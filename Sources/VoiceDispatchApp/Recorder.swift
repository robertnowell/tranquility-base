import AVFoundation
import Foundation
import ObjCExceptionFirewall
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

    /// Optional live-transcription stream, one per utterance. Set once at app
    /// init; the Recorder creates a stream at every mic-open and feeds it from
    /// the tap. The stream can only ever ADD speed — the durable buffer and the
    /// file-based recovery path are untouched whatever the stream does.
    public var streamFactory: (@Sendable () -> StreamedUtterance?)?
    private var stream: StreamedUtterance?
    private var running = false

    /// Live input level, for a waveform or an orb pulse.
    public private(set) var level: Float = 0
    /// Loudest moment of the current recording; the silence gate reads it.
    public private(set) var peakLevel: Float = 0

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

    /// `openingStream: false` is the instant-arm path (docs/instant-arm.md):
    /// capture begins optimistically at the arm window WITHOUT creating a
    /// StreamedUtterance — no network session for audio that a tap will
    /// discard. The stream attaches at hold-resolution via `openStream()`,
    /// which feeds it everything buffered since this call.
    public func start(openingStream: Bool = true) throws {
        guard Self.microphoneAuthorized() else { throw RecorderError.microphoneDenied }
        lock.lock()
        guard !running else { lock.unlock(); return }
        buffer.removeAll(keepingCapacity: true)
        peakLevel = 0
        running = true
        if let stale = stream {
            // An aborted utterance never took its stream; close it quietly.
            stream = nil
            Task { _ = await stale.finish(timeout: 0) }
        }
        if openingStream {
            stream = streamFactory?()
            if let s = stream { Task { await s.start() } }
        }
        lock.unlock()

        // Replying while the announcement is still playing is the normal case,
        // and it is exactly when the audio device is mid route-change: the input
        // briefly reports 0 Hz / 0 channels, and installTap on that format
        // throws an ObjC NSException rather than a Swift error. The change
        // settles in tens of milliseconds, so ride through it — a press during
        // playback must open the mic, not report an error about audio plumbing.
        // Worst case here is ~480ms before giving up, well under the event-tap
        // watchdog.
        var lastReason = "unknown"
        for attempt in 0..<6 {
            if attempt > 0 { usleep(80_000) }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                lastReason = "input format invalid (rate=\(format.sampleRate), "
                    + "channels=\(format.channelCount)) — audio device mid route-change"
                continue
            }

            // Firewalled: any NSException AVFoundation still throws becomes a
            // Swift error instead of unwinding through the caller's main-queue
            // block. One such unwind wedged the main dispatch queue permanently —
            // panel frozen, gestures dead, main thread sampling as idle
            // (2026-08-05, 18:01:11Z).
            var startError: Error?
            let exception = VDCatchObjCException {
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] pcmBuffer, _ in
                    guard let self else { return }
                    if let converted = BuddyPCM16Converter.pcm16Data(
                        from: pcmBuffer, targetSampleRate: self.sampleRate) {
                        self.lock.lock()
                        self.buffer.append(converted)
                        let liveStream = self.stream
                        self.lock.unlock()
                        liveStream?.feed(pcm16: converted)
                    }
                    let rms = Self.rms(of: pcmBuffer)
                    self.level = rms
                    if rms > self.peakLevel { self.peakLevel = rms }
                }
                engine.prepare()
                do { try engine.start() } catch { startError = error }
            }

            if exception == nil && startError == nil {
                if attempt > 0 {
                    Permissions.log("mic: opened on attempt \(attempt + 1) after: \(lastReason)")
                }
                return
            }
            _ = VDCatchObjCException { input.removeTap(onBus: 0); engine.stop() }
            lastReason = exception.map { "\($0.name.rawValue): \($0.reason ?? "no reason")" }
                ?? "\(startError!)"
        }

        lock.lock(); running = false; lock.unlock()
        throw RecorderError.engineFailed(lastReason)
    }

    /// Attach the live stream to a capture that is already running — the
    /// instant-arm upgrade (docs/instant-arm.md). Everything buffered since
    /// the mic opened is fed FIRST, under the same lock the tap uses to
    /// publish the stream, so no live chunk can jump ahead of the backlog:
    /// the tap reads `stream` under this lock, and any chunk that read nil
    /// is already in the backlog being fed here. Pre-socket delivery rides
    /// StreamedUtterance's own pre-open buffer (the buffer-then-flush design
    /// documented in AssemblyAIStreaming.swift), so the transcript covers
    /// the arm window even though the socket opens after this returns.
    public func openStream() {
        lock.lock()
        guard running, stream == nil else { lock.unlock(); return }
        let s = streamFactory?()
        if let s, !buffer.isEmpty { s.feed(pcm16: buffer) }
        stream = s
        lock.unlock()
        if let s { Task { await s.start() } }
    }

    /// Seconds of audio captured so far (PCM16 mono at `sampleRate`) — the
    /// arm-window accounting the latency log reports at upgrade.
    public var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(buffer.count) / 2.0 / sampleRate
    }

    /// Take ownership of this utterance's live stream (nil if none was created
    /// or it was already taken). Callers `await finish()` it — which returns nil
    /// on ANY stream problem, in which case the file path recovers as always.
    public func takeStream() -> StreamedUtterance? {
        lock.lock(); defer { lock.unlock() }
        let s = stream
        stream = nil
        return s
    }

    /// Stop capturing and hand back everything recorded. The caller persists it
    /// before doing anything else.
    @discardableResult
    public func stop() throws -> Data {
        lock.lock()
        guard running else { lock.unlock(); throw RecorderError.nothingRecorded }
        running = false
        lock.unlock()

        _ = VDCatchObjCException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
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
        _ = VDCatchObjCException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        level = 0
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
    }
}
