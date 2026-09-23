import AVFoundation
import XCTest
@testable import TranquilityCore

/// The compression is a latency fix on the path that runs after something has
/// already gone wrong, so every test here is really asking the same question:
/// can it ever make a recovery worse than not compressing at all?
final class CompressedAudioTests: XCTestCase {
    private func wav(seconds: Double, at url: URL) throws {
        let rate = 16_000.0
        var pcm = Data()
        for i in 0..<Int(rate * seconds) {
            // Speech-ish rather than a pure tone, so the encoder does real work
            // and the size assertions mean something.
            let envelope = 0.5 * (1 + sin(2 * .pi * Double(i) / (rate * 0.35)))
            let value = Int16(max(-32_000, min(32_000, 9_000 * envelope * sin(2 * .pi * 180 * Double(i) / rate))))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        try BuddyWAVBuilder.wavData(fromPCM16: pcm, sampleRate: rate).write(to: url)
    }

    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed-audio-test-\(UUID().uuidString)-\(name)")
    }

    func testCompressesAMinuteToAFractionOfTheWAV() throws {
        let source = temp("minute.wav")
        try wav(seconds: 60, at: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let compressed = try XCTUnwrap(CompressedAudio.m4a(from: source))
        defer { try? FileManager.default.removeItem(at: compressed) }

        let big = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let small = try compressed.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        XCTAssertEqual(compressed.pathExtension, "m4a")
        // A minute of PCM16 at 16 kHz is ~1.92 MB; at 48 kbps it is ~0.36 MB.
        // Assert the order of magnitude, not the encoder's exact output.
        XCTAssertLessThan(small * 4, big, "expected at least a 4x saving, got \(big) -> \(small)")
        XCTAssertGreaterThan(small, 0)
    }

    /// The whole recording, not a prefix. A compression that silently dropped
    /// the tail would lose exactly the part a long dictation was recovered for.
    func testKeepsTheWholeDuration() throws {
        let source = temp("duration.wav")
        try wav(seconds: 12, at: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let compressed = try XCTUnwrap(CompressedAudio.m4a(from: source))
        defer { try? FileManager.default.removeItem(at: compressed) }

        let read = try AVAudioFile(forReading: compressed)
        let seconds = Double(read.length) / read.fileFormat.sampleRate
        XCTAssertEqual(seconds, 12, accuracy: 0.25)
    }

    /// Never beside the original: the audio store owns its directory.
    func testWritesToATempFileNotNextToTheRecording() throws {
        let source = temp("placement.wav")
        try wav(seconds: 2, at: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let compressed = try XCTUnwrap(CompressedAudio.m4a(from: source))
        defer { try? FileManager.default.removeItem(at: compressed) }

        XCTAssertTrue(compressed.lastPathComponent.hasPrefix("tb-compressed-"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: source.deletingPathExtension().appendingPathExtension("m4a").path),
            "compressed copy must not be written beside the recording")
    }

    /// Nothing to compress is not a crash and not an exception: it is nil, and
    /// nil means "send the original".
    func testUnreadableOrEmptyInputReturnsNil() throws {
        XCTAssertNil(CompressedAudio.m4a(from: temp("missing.wav")))

        let garbage = temp("garbage.wav")
        try Data("this is not audio".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        XCTAssertNil(CompressedAudio.m4a(from: garbage))
    }
}
