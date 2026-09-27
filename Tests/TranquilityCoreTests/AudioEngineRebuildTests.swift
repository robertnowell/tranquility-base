import XCTest
@testable import TranquilityCore

/// One engine, two halves. These hold the rule that 27 Sep earned: a playout
/// rebuild may not cost the microphone, and a microphone that was already off
/// may not be switched on by one.
final class AudioEngineRebuildTests: XCTestCase {

    /// A module that behaves like the real one: restarting playout restarts the
    /// engine, and `dropsMicOnRestart` says whether that takes the input half
    /// with it — which is exactly the behaviour under test.
    private final class Module: AudioEngineRebuild.Halves {
        var playing = false
        var recording = false
        var dropsMicOnRestart = false
        var calls: [String] = []

        init(playing: Bool = true, recording: Bool = true, dropsMic: Bool = false) {
            self.playing = playing; self.recording = recording
            self.dropsMicOnRestart = dropsMic
        }
        func stopPlayout() -> Int { calls.append("stopPlayout"); playing = false; return 0 }
        func initPlayout() -> Int {
            calls.append("initPlayout")
            if dropsMicOnRestart { recording = false }
            return 0
        }
        func startPlayout() -> Int { calls.append("startPlayout"); playing = true; return 0 }
        func initRecording() -> Int { calls.append("initRecording"); return 0 }
        func startRecording() -> Int { calls.append("startRecording"); recording = true; return 0 }
    }

    /// The 27 Sep failure, and the fix. Before this, the rebuild stopped at
    /// startPlayout and left `recording` false for the rest of the session:
    /// 41 seconds of audio reached the transcriber out of 76, and two
    /// sentences were cut in half with nothing on screen to say why.
    func testTheMicrophoneComesBackWhenTheRestartTakesIt() {
        let adm = Module(dropsMic: true)
        let out = AudioEngineRebuild.rebuild(adm)
        XCTAssertTrue(out.microphoneDropped)
        XCTAssertTrue(out.recording)
        XCTAssertTrue(adm.recording)
        XCTAssertEqual(adm.calls,
                       ["stopPlayout", "initPlayout", "startPlayout",
                        "initRecording", "startRecording"])
        XCTAssertTrue(out.line.contains("MICROPHONE DROPPED BY THE REBUILD"))
    }

    /// The ordinary case must stay ordinary: an engine that keeps its input
    /// half is not touched, and the line does not cry wolf.
    func testAnUndisturbedMicrophoneIsLeftAlone() {
        let adm = Module(dropsMic: false)
        let out = AudioEngineRebuild.rebuild(adm)
        XCTAssertFalse(out.microphoneDropped)
        XCTAssertTrue(out.recording)
        XCTAssertEqual(adm.calls, ["stopPlayout", "initPlayout", "startPlayout"])
        XCTAssertFalse(out.line.contains("DROPPED"))
        XCTAssertTrue(out.line.contains("recording yes"))
    }

    /// The reading that has to be taken BEFORE the rebuild. Hands-free is
    /// stopping, or has not started; the microphone is off on purpose. A
    /// rebuild that switched it on here would open the microphone at exactly
    /// the moment the user asked for it to be shut, which is the one failure
    /// worse than the one this fixes.
    func testAMicrophoneThatWasAlreadyOffIsNotStarted() {
        let adm = Module(recording: false, dropsMic: true)
        let out = AudioEngineRebuild.rebuild(adm)
        XCTAssertFalse(out.microphoneDropped)
        XCTAssertFalse(out.recording)
        XCTAssertFalse(adm.recording)
        XCTAssertEqual(adm.calls, ["stopPlayout", "initPlayout", "startPlayout"])
    }

    /// A re-arm that itself fails is reported, not swallowed. The codes are in
    /// the line because the next person to read this log needs the module's
    /// own answer, not ours.
    func testAFailedReArmSaysSo() {
        final class Stubborn: AudioEngineRebuild.Halves {
            var playing = true
            var recording = true
            func stopPlayout() -> Int { recording = false; return 0 }
            func initPlayout() -> Int { 0 }
            func startPlayout() -> Int { 0 }
            func initRecording() -> Int { -1 }
            func startRecording() -> Int { -1 }
        }
        let out = AudioEngineRebuild.rebuild(Stubborn())
        XCTAssertTrue(out.microphoneDropped)
        XCTAssertFalse(out.recording)
        XCTAssertTrue(out.line.contains("init -1, start -1"))
        XCTAssertTrue(out.line.contains("recording no"))
    }
}
