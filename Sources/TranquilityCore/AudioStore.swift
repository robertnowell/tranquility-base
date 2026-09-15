import AVFoundation
import CryptoKit
import Foundation

/// Writes captured audio to disk and links it to its queue row.
///
/// The ordering is the whole point: audio is flushed **at key-up, before the first
/// network call**, and the row is committed alongside it. From that moment the
/// utterance is recoverable no matter what fails afterwards — transcription, the
/// network, the app. Both donor codebases got this wrong in the same direction:
/// Clicky never wrote audio to disk at all, and OpenWhispr wrote it only *after*
/// the transcription attempt, so the first failure had nothing to retry from.
///
/// Uncompressed WAV is deliberate. A truncated WAV is still parseable up to the
/// last flushed frame; a truncated compressed container usually isn't, because its
/// index is written at the end. Utterances are seconds long, so the disk cost is
/// irrelevant next to that property.
public struct AudioStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? QueueStore.audioDirectory
    }

    public struct Stored: Sendable {
        public let url: URL
        public let byteCount: Int64
        public let sha256: String
        public let durationMs: Int64
    }

    /// The row id *is* the filename stem — never a timestamp, never a content hash.
    /// Identity has to survive re-transcription, which changes everything else.
    public func url(for utteranceId: String) -> URL {
        directory.appendingPathComponent("\(utteranceId).wav")
    }

    @discardableResult
    public func write(pcm16Data: Data, sampleRate: Double, utteranceId: String) throws -> Stored {
        try? PrivateStorage.createDirectory(at: directory)
        let target = url(for: utteranceId)
        let wav = BuddyWAVBuilder.wavData(fromPCM16: pcm16Data, sampleRate: sampleRate)

        // Write to a temp name then move: a crash mid-write leaves no half file
        // that a boot sweep would mistake for a complete recording.
        let temp = target.appendingPathExtension("partial")
        try wav.write(to: temp, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temp, to: target)
        // A recording of the user's voice, so owner-only.
        PrivateStorage.protect(target)

        let bytesPerFrame = 2.0
        let durationMs = Int64((Double(pcm16Data.count) / bytesPerFrame / sampleRate) * 1000)

        return Stored(
            url: target,
            byteCount: Int64(wav.count),
            sha256: SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined(),
            durationMs: durationMs)
    }

    public func exists(_ utteranceId: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: utteranceId).path)
    }

    // MARK: - Resolving a recording in either state

    /// What is actually on disk for an utterance.
    ///
    /// `.wav.live` is not a third kind of file — it is the same recording in an
    /// earlier state (see `LiveAudioCapture`). Before this existed, every sweep
    /// did its own path arithmetic against `<id>.wav` and therefore had to be
    /// taught the live extension separately. Three of them had not been, and one
    /// of those was load-bearing: boot reconciliation discards an in-flight row
    /// whose audio it cannot find, so a capture interrupted mid-utterance — the
    /// exact case write-ahead exists to survive — would have been retired on the
    /// first launch after the crash, with the audio sitting intact beside it.
    ///
    /// One accessor, so the knowledge lives once and the next sweep somebody
    /// writes inherits it rather than re-deriving it wrongly.
    public enum Resolved: Sendable, Equatable {
        /// A complete recording. Every caller behaves as it always has.
        case finished(URL)
        /// A capture a process did not come back from. Recoverable: readable to
        /// the last flushed frame, and promotable by `LiveAudioCapture.adopt`.
        /// **Never treat this as missing.**
        case interrupted(URL)
        /// Genuinely gone.
        case missing
    }

    /// Resolve from the path a row actually recorded, which is the authoritative
    /// one — a row's `audioPath` is where its audio was written, and
    /// reconstructing it from an id plus the default directory is a guess that is
    /// wrong for every caller using a different store (the tests, the replay
    /// tool). Two existing sweep tests caught exactly that mistake.
    public static func resolve(audioPath: String?) -> Resolved {
        guard let audioPath, !audioPath.isEmpty else { return .missing }
        let recorded = URL(fileURLWithPath: audioPath)
        if FileManager.default.fileExists(atPath: recorded.path) { return .finished(recorded) }
        let live = recorded.appendingPathExtension(LiveAudioCapture.liveExtension)
        if FileManager.default.fileExists(atPath: live.path) { return .interrupted(live) }
        return .missing
    }

    public func resolve(utteranceId: String) -> Resolved {
        let finished = url(for: utteranceId)
        if FileManager.default.fileExists(atPath: finished.path) { return .finished(finished) }
        let live = finished.appendingPathExtension(LiveAudioCapture.liveExtension)
        if FileManager.default.fileExists(atPath: live.path) { return .interrupted(live) }
        return .missing
    }

    /// The utterance id a file in the audio directory belongs to, in either
    /// state. `deletingPathExtension()` alone turns `u4.wav.live` into `u4.wav`,
    /// which matches no row id — the bug that made every live capture report as
    /// an orphan forever.
    public static func utteranceId(of url: URL) -> String {
        var trimmed = url
        if trimmed.pathExtension == LiveAudioCapture.liveExtension {
            trimmed = trimmed.deletingPathExtension()
        }
        return trimmed.deletingPathExtension().lastPathComponent
    }

    /// Verify a file still matches what was recorded. Used by the boot sweep before
    /// re-queuing an utterance for transcription.
    public func verify(utteranceId: String, expectedSha256: String?) -> Bool {
        guard let expectedSha256,
              let data = try? Data(contentsOf: url(for: utteranceId)) else { return false }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expectedSha256
    }
}

// MARK: - PCM / WAV
//
// Adapted from Clicky's BuddyAudioConversionSupport (MIT) — the one piece of its
// audio layer worth keeping verbatim, since the conversion itself was never the
// problem.

public enum BuddyPCM16Converter {
    /// Convert a mic buffer to 16-bit mono PCM at the given rate.
    public static func pcm16Data(from buffer: AVAudioPCMBuffer, targetSampleRate: Double = 16000) -> Data? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate,
            channels: 1, interleaved: true) else { return nil }

        if buffer.format.sampleRate == targetSampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatInt16,
           let channel = buffer.int16ChannelData {
            return Data(bytes: channel[0], count: Int(buffer.frameLength) * 2)
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        let ratio = targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }

        // AVAudioPCMBuffer is not Sendable and the input block is @Sendable, but the
        // block is invoked synchronously on this thread — box the state so the
        // compiler can see that, rather than reaching for @preconcurrency.
        final class InputState: @unchecked Sendable {
            var supplied = false
            let buffer: AVAudioPCMBuffer
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let state = InputState(buffer)

        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if state.supplied {
                status.pointee = .noDataNow
                return nil
            }
            state.supplied = true
            status.pointee = .haveData
            return state.buffer
        }
        guard error == nil, let channel = output.int16ChannelData, output.frameLength > 0
        else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
    }
}

extension BuddyPCM16Converter {
    /// Read any audio file AVFoundation can open and convert it to 16-bit mono
    /// PCM at the target rate — the format every transcription provider here
    /// consumes. Used by `tbase transcribe-stream` to replay a saved recording
    /// through the live provider; nil when the file cannot be read.
    public static func pcm16Data(contentsOf url: URL, targetSampleRate: Double = 16000) -> Data? {
        guard let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        guard (try? file.read(into: buffer)) != nil else { return nil }
        return pcm16Data(from: buffer, targetSampleRate: targetSampleRate)
    }
}

/// One converter kept across a capture's buffers.
///
/// A sample-rate converter is a filter with memory: every output sample needs
/// input on both sides of it. `BuddyPCM16Converter.pcm16Data` builds a fresh
/// `AVAudioConverter` per buffer and never asks for the tail, so a 512-frame
/// buffer at 48 kHz yields 165 frames where 170.67 belong: the last third of
/// a millisecond of every buffer was cut and the next buffer glued on, 94
/// times a second. Measured 15 Sep 2026: every capture line in the log was
/// 3.4% shorter than the seconds the mic was open, and a 1 kHz tone through
/// the per-buffer path left a residual at −28 dB against −58 dB through this.
/// It was audible as fuzz riding on the voice, and the level meters could not
/// see it — the energy was all still there, just in the wrong places.
///
/// Feed buffers in order on one thread (AUHAL delivers serially). `reset()`
/// between captures so one utterance's tail never primes the next.
///
/// There is deliberately no `flush()`. The filter holds the last third of a
/// millisecond of a capture at key-up, and handing it back would mean either
/// waiting for the HAL stop to drain (which `Recorder.stop` refuses to do,
/// because a HAL mid-config-change can sit on any call) or sharing the
/// converter between the render thread and the key-up thread under a lock.
/// What that would recover is 5.7 frames once per capture, after the key
/// has been released, which is room tone after the last word. Ruled 15 Sep
/// 2026: once per capture is the fix; 94 times a second was the bug.
public final class StreamingPCM16Converter {
    public let inputFormat: AVAudioFormat
    public let targetFormat: AVAudioFormat
    /// Nil when the input already is 16-bit mono at the target rate.
    private let converter: AVAudioConverter?
    /// Reused across calls: one allocation, none on the render thread.
    private let output: AVAudioPCMBuffer
    public private(set) var framesIn = 0
    public private(set) var framesOut = 0

    public init?(from inputFormat: AVAudioFormat,
                 targetSampleRate: Double = 16000,
                 maxInputFrames: AVAudioFrameCount = 4096) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate,
            channels: 1, interleaved: true) else { return nil }
        self.inputFormat = inputFormat
        self.targetFormat = target
        let passthrough = inputFormat.sampleRate == targetSampleRate
            && inputFormat.channelCount == 1
            && inputFormat.commonFormat == .pcmFormatInt16
        if passthrough {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: inputFormat, to: target) else { return nil }
            converter = c
        }
        let ratio = targetSampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(maxInputFrames) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        output = out
    }

    /// Forget the previous capture's history. Call between captures, on the
    /// same thread that converts.
    public func reset() {
        converter?.reset()
        framesIn = 0
        framesOut = 0
    }

    /// Convert one buffer, keeping filter state for the next. The output is
    /// a little shorter than `frames × ratio` on the first call (the filter's
    /// run-up, a third of a millisecond at 48→16 kHz) and whole thereafter.
    public func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        framesIn += Int(buffer.frameLength)
        guard let converter else {
            guard let channel = buffer.int16ChannelData else { return nil }
            framesOut += Int(buffer.frameLength)
            return Data(bytes: channel[0], count: Int(buffer.frameLength) * 2)
        }
        final class InputState: @unchecked Sendable {
            var supplied = false
            let buffer: AVAudioPCMBuffer
            init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let state = InputState(buffer)
        output.frameLength = 0
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if state.supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.supplied = true
            outStatus.pointee = .haveData
            return state.buffer
        }
        guard status != .error, error == nil,
              let channel = output.int16ChannelData, output.frameLength > 0
        else { return nil }
        framesOut += Int(output.frameLength)
        return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
    }
}

public enum BuddyWAVBuilder {
    public static func wavData(fromPCM16 pcm: Data, sampleRate: Double, channels: UInt16 = 1) -> Data {
        var out = Data()
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { out.append(contentsOf: $0) }
        }

        out.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))            // PCM
        append(channels)
        append(UInt32(sampleRate))
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        out.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        out.append(pcm)
        return out
    }
}
