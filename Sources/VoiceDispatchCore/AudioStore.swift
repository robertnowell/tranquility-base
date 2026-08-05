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
    /// consumes. Used by `vdctl transcribe-stream` to replay a saved recording
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
