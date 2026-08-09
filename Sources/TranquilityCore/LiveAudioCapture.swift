import CryptoKit
import Foundation

/// A recording that is on disk *while it is still being spoken*.
///
/// `AudioStore.write(pcm16Data:…)` persists an utterance once, at key-up. Its
/// header states the reasoning: per-chunk write-ahead was rejected because "the
/// failures that actually happen are network and API ones, which a single flush
/// at release covers."
///
/// That premise was falsified on 08 Aug 2026, by measurement rather than
/// argument (CLAUDE.md rule 4). Six recordings were lost between 23:06:50 and
/// 23:12:43 PDT — each one started, ran with hands-free listening locked, and
/// was still open when a parallel session's `scripts/relaunch.sh` replaced the
/// process. `app.log` has every one as a `recording started` with no matching
/// `transcription started`. There is a third failure class the original
/// reasoning does not name: **the process going away mid-utterance**. Against
/// it, a flush at release protects nothing, because release never happens.
///
/// Note what was NOT the cause, since the log looks like it was: the
/// `state: REFUSED listening -> idle (grid from announceNext…)` lines in the
/// same seconds are `PanelState.allowsAmbientSurface` doing its job — an
/// arrival correctly refused the stage while capture owned it. The panel gate
/// held. Only the in-memory buffer was lost.
///
/// So this type keeps the same guarantees the single-flush design was chosen
/// for, and moves the moment they start applying from key-up to the first
/// frame:
///
/// - **Uncompressed WAV**, for the reason `AudioStore` already gives — a
///   truncated WAV is parseable up to the last flushed frame, where a truncated
///   compressed container usually is not, because its index lives at the end.
///   The format was picked so a partial file would survive; until now nothing
///   ever wrote one.
/// - **The header is rewritten after every append**, so the file on disk is a
///   *valid* WAV at all times, not merely a recoverable one. Two four-byte
///   fields per chunk is the whole cost.
/// - **A distinct extension while live** (`.wav.live`), so the boot sweep can
///   tell "a recording that was interrupted" from "a complete recording",
///   without either one being mistaken for the other. `AudioStore.write` makes
///   the same distinction with `.partial`; this is the same idea held open for
///   the length of an utterance instead of the length of a write.
public final class LiveAudioCapture: @unchecked Sendable {
    /// Live recordings carry this while they are still being spoken. A file
    /// with this extension in the audio directory means a process died holding
    /// a microphone open — see `LiveAudioCapture.interrupted(in:)`.
    public static let liveExtension = "live"

    public let utteranceId: String
    public let url: URL
    private let sampleRate: Double
    private let handle: FileHandle
    private let lock = NSLock()
    private var frameBytes: Int = 0
    private var closed = false

    /// Bytes of PCM written so far. Safe to read from any thread.
    public var byteCount: Int { lock.lock(); defer { lock.unlock() }; return frameBytes }

    /// How much audio is durable right now.
    public var durationMs: Int64 {
        Int64((Double(byteCount) / 2.0 / sampleRate) * 1000)
    }

    /// Open a new live recording. The header is written immediately, so even a
    /// capture that dies before its first `append` leaves a valid empty WAV
    /// rather than a zero-byte file that looks like a disk error.
    public init(utteranceId: String, sampleRate: Double, directory: URL) throws {
        self.utteranceId = utteranceId
        self.sampleRate = sampleRate
        self.url = directory
            .appendingPathComponent("\(utteranceId).wav")
            .appendingPathExtension(Self.liveExtension)

        try? PrivateStorage.createDirectory(at: directory)
        let header = BuddyWAVBuilder.wavData(fromPCM16: Data(), sampleRate: sampleRate)
        try header.write(to: url, options: .atomic)
        // A recording of the user's voice, owner-only from the first byte —
        // not from the moment it is finished.
        PrivateStorage.protect(url)

        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    /// Append newly captured PCM16 and make it durable.
    ///
    /// Throwing here must never take down a recording that is otherwise fine:
    /// callers treat a failed append as "this chunk is not durable", not as
    /// "stop recording". The in-memory buffer remains the primary path; this is
    /// the copy that survives the process.
    public func append(pcm16: Data) throws {
        guard !pcm16.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        try handle.write(contentsOf: pcm16)
        frameBytes += pcm16.count
        try rewriteSizes()
    }

    /// The two little-endian length fields a WAV reader trusts: the RIFF chunk
    /// size at offset 4, and the data chunk size at offset 40. Rewriting them
    /// after every append is what makes the file valid mid-recording rather
    /// than merely salvageable.
    private func rewriteSizes() throws {
        func le32(_ value: Int) -> Data {
            var little = UInt32(value).littleEndian
            return withUnsafeBytes(of: &little) { Data($0) }
        }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: le32(36 + frameBytes))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: le32(frameBytes))
        try handle.seekToEnd()
        try handle.synchronize()
    }

    /// Promote the live file to a finished recording, atomically.
    ///
    /// Returns the same `Stored` shape `AudioStore.write` returns, so a caller
    /// can use either path without knowing which one produced the file.
    @discardableResult
    public func finish() throws -> AudioStore.Stored {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CocoaError(.fileWriteUnknown) }
        try rewriteSizes()
        try handle.close()
        closed = true

        let target = url.deletingPathExtension()
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: url, to: target)
        PrivateStorage.protect(target)

        let data = (try? Data(contentsOf: target)) ?? Data()
        return AudioStore.Stored(
            url: target,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            durationMs: Int64((Double(frameBytes) / 2.0 / sampleRate) * 1000))
    }

    /// Give up on this recording and remove the file.
    ///
    /// For the arm-window discard (docs/instant-arm.md), where the capture was
    /// optimistic and the user never committed to it. Distinct from a process
    /// dying: that one deliberately leaves the file behind to be found.
    public func abandon() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        try? handle.close()
        closed = true
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Recovery

    /// Recordings a previous process left open, newest first.
    ///
    /// A `.wav.live` file in the audio directory can only mean one thing: a
    /// process held a microphone and did not come back. Nothing writes this
    /// extension except an in-progress capture, and every ordinary ending —
    /// `finish` or `abandon` — removes it.
    public static func interrupted(in directory: URL) -> [Interrupted] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }

        return files
            .filter { $0.pathExtension == liveExtension }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                // 44 bytes is a header and no audio: the capture died before a
                // single frame landed. There is nothing to recover, and
                // offering it would be worse than silence.
                guard size > 44 else { return nil }
                return Interrupted(
                    utteranceId: url.deletingPathExtension().deletingPathExtension()
                        .lastPathComponent,
                    url: url,
                    byteCount: size,
                    modifiedAt: values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public struct Interrupted: Sendable, Equatable {
        public let utteranceId: String
        public let url: URL
        public let byteCount: Int
        public let modifiedAt: Date

        /// Seconds of audio that survived, from the file's own length.
        public func durationMs(sampleRate: Double = 16000) -> Int64 {
            Int64((Double(max(0, byteCount - 44)) / 2.0 / sampleRate) * 1000)
        }
    }

    /// Adopt an interrupted recording as a finished one, so it can be
    /// transcribed by the ordinary path.
    ///
    /// Deliberately not automatic: whether an interrupted capture is worth
    /// offering back is the app's decision, and doing it at discovery time
    /// would mean a boot sweep silently resurrecting audio the user has already
    /// forgotten saying.
    @discardableResult
    public static func adopt(_ interrupted: Interrupted) throws -> URL {
        let target = interrupted.url.deletingPathExtension()
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: interrupted.url, to: target)
        PrivateStorage.protect(target)
        return target
    }
}
