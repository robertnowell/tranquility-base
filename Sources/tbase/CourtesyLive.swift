import AVFoundation
import Foundation
import TranquilityCore

/// Opens the REAL microphone for the real window and returns what it heard.
///
/// The point of this file is the one thing the fixture tests cannot cover: every
/// test so far fed `assess()` clean samples at effectively zero distance, and
/// `SFSpeechRecognizer` is tuned for someone speaking INTO a device. Whether it
/// hears two people across a room is the question the feature lives or dies on,
/// and it is only answerable by putting real air between a voice and the mic.
///
/// Deliberately NOT `Recorder`: that lives in the app target, carries the
/// retry/format-mismatch hardening earned by the AirPods incidents, and has no
/// business growing an eval entry point. This is a measuring instrument, not a
/// shipping path — if it fails where `Recorder` would have retried, that shows
/// up as a failed sample rather than as a wrong verdict.
enum CourtesyLive {

    /// The grant belongs to whatever launched us — Terminal, iTerm — because a
    /// CLI has no bundle identity of its own. Worth asking explicitly: a denied
    /// microphone does not make `AVAudioEngine.start()` throw, it makes every
    /// buffer zero, and an eval that cannot tell those apart reports a perfectly
    /// silent room and a broken detector with the same number.
    static func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Capture `seconds` of the real room at 16k mono PCM16.
    static func sample(seconds: Double) throws -> [Int16] {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw Failure.badFormat("rate=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount)")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else { throw Failure.badFormat("no converter from \(inputFormat)") }

        let box = Box()
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let ratio = 16000 / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
            else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let channel = out.floatChannelData?[0]
            else { return }
            var chunk = [Int16](repeating: 0, count: Int(out.frameLength))
            for i in 0..<Int(out.frameLength) {
                chunk[i] = Int16(max(-1, min(1, channel[i])) * 32767)
            }
            box.append(chunk)
        }

        engine.prepare()
        try engine.start()
        Thread.sleep(forTimeInterval: seconds)
        input.removeTap(onBus: 0)
        engine.stop()
        return box.take()
    }

    enum Failure: Error, CustomStringConvertible {
        case badFormat(String)
        var description: String {
            switch self { case .badFormat(let s): return "input format unusable: \(s)" }
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Int16] = []
        func append(_ chunk: [Int16]) {
            lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        }
        func take() -> [Int16] {
            lock.lock(); defer { lock.unlock() }
            return samples
        }
    }
}
