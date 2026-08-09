import AVFoundation
import Foundation
import Speech
import TranquilityCore

/// Fixtures for `tbase courtesy`, so the courtesy check can be demonstrated
/// without standing in a room and hoping.
///
/// The speech is synthesised with `say` rather than recorded, which makes the
/// corpus reproducible on any Mac, keeps binary audio out of the repo, and means
/// no real third party's voice is ever committed. The same trick backs the
/// integration tests in CourtesyCheckTests.
enum CourtesyDemo {

    /// The demo runs from a terminal, where speech-recognition authorisation
    /// belongs to the terminal app rather than to this binary. Ask once if the
    /// answer is not yet known; never in the app itself, which already holds the
    /// grant through `AppleSpeechRecovery`.
    static func authorizeIfNeeded() async {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            print("requesting speech-recognition authorisation (one-time, for your terminal)…")
            _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
        case .denied, .restricted:
            print("speech recognition is denied for this terminal — the check will")
            print("degrade to speaking, which is the ruled behaviour. Noise rows still work.\n")
        @unknown default:
            return
        }
    }

    /// One row per scenario in the evidence plan's matrix that can be produced
    /// without hardware: silence, wordless noise, a pure tone, and real speech.
    static func corpus(speaking sentence: String) throws -> [(String, [Int16])] {
        [
            ("silence", silence()),
            ("quiet room", noise(amplitude: 0.01)),
            ("loud fan / traffic", noise(amplitude: 0.3)),
            ("pure tone", tone()),
            ("someone talking", try spoken(sentence)),
        ]
    }

    static func silence(seconds: Double = 2, rate: Double = 16000) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * rate))
    }

    static func noise(amplitude: Double, seconds: Double = 2, rate: Double = 16000) -> [Int16] {
        var state: UInt64 = 0x5DEECE66D
        return (0..<Int(seconds * rate)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(1 << 53) * 2 - 1
            return Int16(max(-32767, min(32767, unit * amplitude * 32767)))
        }
    }

    static func tone(hz: Double = 440, amplitude: Double = 0.4,
                     seconds: Double = 2, rate: Double = 16000) -> [Int16] {
        (0..<Int(seconds * rate)).map { i in
            Int16(sin(2 * .pi * hz * Double(i) / rate) * amplitude * 32767)
        }
    }

    /// `say` to a temp WAV, read back as PCM16, file deleted immediately. The
    /// only audio this repo ever writes for the courtesy check, and it is
    /// synthetic.
    static func spoken(_ text: String, rate: Double = 16000) throws -> [Int16] {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tb-courtesy-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--file-format=WAVE",
                         "--data-format=LEI16@\(Int(rate))", text]
        try say.run()
        say.waitUntilExit()

        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              case _ = try file.read(into: buffer),
              let channel = buffer.floatChannelData?[0]
        else { return [] }
        return (0..<Int(buffer.frameLength)).map {
            Int16(max(-1, min(1, channel[$0])) * 32767)
        }
    }
}
