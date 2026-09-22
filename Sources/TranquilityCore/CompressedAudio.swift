import AVFoundation
import Foundation

/// A recording, made small enough that sending it is not the slow part.
///
/// The app records mono 16 kHz PCM16 — 1.92 MB a minute — and the cloud
/// recovery rungs upload that WAV as it is. Measured over 62 real recoveries
/// (7–22 Sep), the upload is most of the wait: a one-minute recording
/// recovers in 4.6 s, a 23-minute one in 41.6 s, and the vendor's own
/// transcription of a 27-minute file takes about thirty seconds of that.
/// The rest is 42 MB going up a domestic uplink.
///
/// AAC removes about seven eighths of those bytes for well under a second of
/// CPU, so this is a latency fix that happens to also retire two size
/// problems: Whisper's 25 MB cap (and its lower real one, which is why that
/// rung slices at five minutes), and the 32 MiB request limit any HTTP/1
/// service would impose on a managed recovery route later.
public enum CompressedAudio {
    /// 48 kbps, chosen by measurement rather than taste.
    ///
    /// Transcribing the same 22.8-minute recording both ways through the same
    /// vendor and comparing word for word:
    ///
    ///     same WAV twice (the vendor's own nondeterminism)   99.90%
    ///     AAC 48 kbps vs WAV                                 99.21%
    ///     AAC 32 kbps vs WAV                                 98.28%
    ///
    /// So 48 kbps lands within 0.7 points of the ceiling that repeating the
    /// identical file gives, while 32 kbps costs a real 1.6 — mostly fillers
    /// and contraction style, but it also turned one "Claude" into "pod".
    /// 48 kbps still makes that file 5.3x smaller (41.7 MB to 7.9 MB) and cut
    /// its whole recovery from 21.9 s to 11.2 s.
    public static let bitRate = 48_000

    /// Compress `url` beside itself, or return nil.
    ///
    /// Nil is not a failure anybody needs to handle: it means the caller
    /// should send what it already has. A recovery is the path that runs
    /// after something has already gone wrong, and refusing to transcribe a
    /// recording because it could not be made smaller would be the worst
    /// possible trade.
    public static func m4a(from url: URL) -> URL? {
        guard let source = try? AVAudioFile(forReading: url) else { return nil }
        let format = source.processingFormat
        // A temp file, never beside the original: the audio store owns its
        // directory and expects to know what is in it. The caller deletes this
        // when it is done with it.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-compressed-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
        guard let out = try? AVAudioFile(forWriting: destination, settings: settings),
              // The encoder decides its own processing format; if it disagrees
              // with the source's, a converter belongs here and does not exist
              // yet. Send the original rather than write something wrong.
              out.processingFormat == format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16)
        else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }

        do {
            while source.framePosition < source.length {
                try source.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try out.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }

        // An "compressed" file that is not smaller is a compression that did
        // nothing, and one that is empty is a compression that lost the
        // recording. Either way, send the original.
        guard let small = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let big = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              small > 0, small < big
        else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        return destination
    }
}
