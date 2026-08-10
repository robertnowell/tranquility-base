import AVFoundation
import Foundation
import Speech
import TranquilityCore

/// The acoustic evaluation, run from inside the app bundle.
///
/// It lives here for one reason: **the microphone grant belongs to this bundle.**
/// A CLI has no identity of its own, so TCC attributes it to the terminal that
/// launched it — and on this machine Terminal is denied, which the first eval run
/// discovered the expensive way (every stimulus, including speech at full volume,
/// came back as digital silence). The permission cannot move, so the harness did.
///
/// Running here is also better evidence. It exercises `Recorder.sampleRoom`, the
/// exact path that ships, rather than a second capture implementation written for
/// the test — which is the failure mode where a harness proves something true of
/// itself and nothing else.
///
/// Same standing as `SelfTest`: this repo already puts the evidence that cannot
/// live in `swift test` behind a launch flag, because the panel needs a window
/// server and this needs a microphone grant. Neither is reachable from XCTest.
///
/// Entered before AppKit — no status item, no hotkey, no panel — so a second
/// instance launched for a measurement can never race the running one for the
/// global hotkey.
///
/// ## KNOWN LIMITATION, measured 10 Aug: the recogniser cannot answer in here
///
/// Every case run through this harness reports `recogniser timed out after 10s —
/// no result, no error`, INCLUDING after the speech grant was obtained, while
/// the very same captured audio recognises fine when `tbase courtesy-file` reads
/// it back (14 words near, 14 mid, 4 far, 4 across pauses).
///
/// The difference is not authorisation and not the audio. It is this file: the
/// eval runs before `NSApplication` exists and blocks the main thread on a
/// `DispatchSemaphore` while it waits. Speech delivers its callbacks to the main
/// queue, so the callback can never be serviced — the deadlock is ours.
///
/// Two consequences, and the second matters more:
///
/// 1. **This harness cannot measure the recogniser.** It can measure levels and
///    capture audio faithfully; recognition has to be read back out of process
///    (`tbase courtesy-file`), which is what the eval script now does.
/// 2. **It says nothing bad about production.** The real app runs
///    `NSApplication.run()`, so its main queue is live and the callback has
///    somewhere to land. The only honest end-to-end test is a real arrival in
///    the running app, read out of `app.log`.
///
/// Fixing this properly means running the eval after AppKit is up rather than
/// before it — which reintroduces the status-item/hotkey race this placement
/// exists to avoid. Not worth it while out-of-process readback works.
enum CourtesyEval {

    /// One row of the plan: what to play, and how loud.
    private struct Case {
        let label: String
        let volume: Int
        let stimulus: String?   // nil = play nothing
    }

    /// Read `manifest` (label⇥volume⇥path), run each case, write results to `out`.
    ///
    /// The stimuli are authored by scripts/courtesy-eval.sh rather than here: the
    /// app has no business knowing how to synthesise a fan, and keeping the
    /// authoring in the script means the corpus can change without rebuilding.
    static func run(manifest: String, out: String, seconds: Double) {
        let originalVolume = shell("osascript", ["-e", "output volume of (get volume settings)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            if !originalVolume.isEmpty {
                _ = shell("osascript", ["-e", "set volume output volume \(originalVolume)"])
            }
        }

        guard let text = try? String(contentsOfFile: manifest, encoding: .utf8) else {
            write("ERROR\tcannot read manifest \(manifest)\n", to: out); return
        }
        let cases: [Case] = text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, let volume = Int(f[1]) else { return nil }
            let path = f.count > 2 && !f[2].isEmpty ? f[2] : nil
            return Case(label: f[0], volume: volume, stimulus: path)
        }

        let recorder = Recorder()
        var report = ""

        // Surface why the recogniser refuses, instead of letting it vanish into
        // "no recogniser — speaking anyway".
        let traceLines = TraceBox()
        CourtesyCheck.trace = { traceLines.add($0) }

        // Report BOTH grants as this bundle sees them, because the first two eval
        // runs were each derailed by a permission rather than by the detector,
        // and an eval that cannot say which is which is worth nothing.
        //
        // These are separate TCC categories: the terminal holds speech and not
        // the microphone, this bundle holds the microphone and (as of 09 Aug)
        // has never once ASKED for speech. Nothing in Sources/ calls
        // SFSpeechRecognizer.requestAuthorization.
        let speechStatus: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechStatus = "authorized"
        case .denied: speechStatus = "denied"
        case .restricted: speechStatus = "restricted"
        case .notDetermined: speechStatus = "notDetermined (never asked)"
        @unknown default: speechStatus = "unknown"
        }
        report += "# speechAuth\t\(speechStatus)\n"
        report += "# micAuth\t\(Recorder.microphoneAuthorized() ? "authorized" : "NOT authorized")\n"
        report += "# onDeviceModel\t"
            + "\(SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition == true)\n"

        for c in cases {
            _ = shell("osascript", ["-e", "set volume output volume \(c.volume)"])
            var player: Process?
            if let stimulus = c.stimulus {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                p.arguments = [stimulus]
                try? p.run()
                player = p
                // Let the sound actually be in the air before we start listening.
                Thread.sleep(forTimeInterval: 0.4)
            }

            let captured = waitForSamples(recorder, seconds: seconds)
            player?.terminate()

            // Keep the audio. The app can capture but (today) cannot recognise;
            // the CLI can recognise but cannot capture. Writing the window to
            // disk is what lets the two halves of the question be answered by
            // the two processes that can each answer one — without granting
            // anything new to either.
            let wav = (out as NSString).deletingLastPathComponent
                + "/captured-" + c.label.replacingOccurrences(of: " ", with: "-") + ".wav"
            if let samples = captured { writeWAV(samples, to: wav) }

            let assessment = captured == nil ? nil
                : waitForAssessment(captured!)

            let verdict = assessment.map { $0.speechDetected ? "HOLD" : "SPEAK" } ?? "ERROR"
            let level = assessment.map { String(format: "%.4f", $0.level) } ?? "-"
            let words = assessment.flatMap { $0.wordCount }.map(String.init) ?? "-"
            let reason = assessment?.reason ?? "no sample taken (device busy or denied)"
            report += "\(c.label)\t\(c.volume)\t\(verdict)\t\(level)\t\(words)\t\(reason)\n"
            // Between cases: let the device settle and any afplay drain, so one
            // case's tail cannot be measured as the next case's room.
            Thread.sleep(forTimeInterval: 0.6)
        }

        for line in traceLines.all() { report += "# trace\t\(line)\n" }
        write(report, to: out)
    }

    private final class TraceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) {
            lock.lock(); if !lines.contains(s) { lines.append(s) }; lock.unlock()
        }
        func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private static func waitForSamples(_ recorder: Recorder, seconds: Double) -> [Int16]? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SamplesBox()
        Task { box.value = await recorder.sampleRoom(seconds: seconds); semaphore.signal() }
        semaphore.wait()
        return box.value
    }

    private static func waitForAssessment(_ samples: [Int16]) -> CourtesyCheck.Assessment? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            box.value = await CourtesyCheck().assess(samples: samples, sampleRate: 16000)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private final class SamplesBox: @unchecked Sendable { var value: [Int16]? }

    /// 16k mono PCM16 WAV, by hand — no AVAudioFile, because the point is a file
    /// another process can read, not a recording the app keeps.
    private static func writeWAV(_ samples: [Int16], to path: String) {
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); le32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16); le16(1); le16(1)
        le32(16000); le32(32000); le16(2); le16(16)
        d.append(contentsOf: Array("data".utf8)); le32(bytes)
        for s in samples { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        try? d.write(to: URL(fileURLWithPath: path))
    }

    private final class ResultBox: @unchecked Sendable {
        var value: CourtesyCheck.Assessment?
    }

    private static func write(_ text: String, to path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private static func shell(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
