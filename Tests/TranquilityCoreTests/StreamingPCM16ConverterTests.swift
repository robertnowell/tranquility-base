import AVFoundation
import Foundation
import Testing
@testable import TranquilityCore

/// The rate converter keeps its history across buffers. Found 15 Sep 2026:
/// a fresh converter per 512-frame buffer yielded 165 frames where 170.67
/// belong, 94 times a second, audible as fuzz on the voice; the app's own
/// capture lines had been 3.4% shorter than the mic-open time all along.
struct StreamingPCM16ConverterTests {
    static let inputRate = 48_000.0
    static let chunk: AVAudioFrameCount = 512

    /// A 1 kHz sine at the microphone's rate, cut into AUHAL-sized buffers.
    static func toneBuffers(seconds: Double) -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1)!
        let total = Int(inputRate * seconds)
        var buffers: [AVAudioPCMBuffer] = []
        var pos = 0
        while pos < total {
            let n = min(Int(chunk), total - pos)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            for i in 0..<n {
                b.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * 1000 * Double(pos + i) / inputRate))
            }
            buffers.append(b)
            pos += n
        }
        return buffers
    }

    static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    @Test func everyFrameOfEveryBufferSurvives() {
        let buffers = Self.toneBuffers(seconds: 2)
        let converter = StreamingPCM16Converter(from: buffers[0].format)!
        var out = Data()
        for b in buffers { if let d = converter.convert(b) { out.append(d) } }
        let expected = Int(2 * 16_000)
        let got = out.count / 2
        // The filter's run-up is a few frames, once. Anything measured in
        // hundreds is the per-buffer loss coming back.
        #expect(expected - got >= 0 && expected - got <= 16,
                "expected \(expected) frames, got \(got)")
    }

    @Test func theOldPathIsTheDefect() {
        // Pins the failure this class replaces, so the test explains itself:
        // one buffer through the per-buffer converter loses its tail.
        let b = Self.toneBuffers(seconds: 0.1)[0]
        let frames = BuddyPCM16Converter.pcm16Data(from: b)!.count / 2
        #expect(frames < 170, "per-buffer conversion yielded \(frames) frames of 170.67")
    }

    @Test func theToneIsContinuousAcrossBufferBoundaries() {
        // A 1 kHz tone at 16 kHz repeats every 16 samples exactly. A splice
        // at a buffer boundary breaks that; a kept filter does not.
        let buffers = Self.toneBuffers(seconds: 1)
        let converter = StreamingPCM16Converter(from: buffers[0].format)!
        var out = Data()
        for b in buffers { if let d = converter.convert(b) { out.append(d) } }
        let x = Self.samples(out)
        var worst = 0
        for i in 200..<x.count { worst = max(worst, abs(Int(x[i]) - Int(x[i - 16]))) }
        // Full scale for the tone is 16384; the per-buffer path measures in
        // the thousands here, a kept converter in the tens.
        #expect(worst < 200, "largest period-to-period jump \(worst)")
    }

    @Test func resetForgetsThePreviousCapture() {
        let buffers = Self.toneBuffers(seconds: 0.5)
        let converter = StreamingPCM16Converter(from: buffers[0].format)!
        for b in buffers { _ = converter.convert(b) }
        converter.reset()
        #expect(converter.framesIn == 0 && converter.framesOut == 0)
        var out = Data()
        for b in buffers { if let d = converter.convert(b) { out.append(d) } }
        let got = out.count / 2
        #expect(8000 - got >= 0 && 8000 - got <= 16, "after reset got \(got) of 8000")
    }

    @Test func passthroughWhenAlreadyTarget() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                   channels: 1, interleaved: true)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        b.frameLength = 160
        for i in 0..<160 { b.int16ChannelData![0][i] = Int16(i) }
        let converter = StreamingPCM16Converter(from: format)!
        #expect(converter.convert(b)?.count == 320)
    }
}
