import Foundation

/// Rebuilding playout must not cost the microphone (27 Sep 2026).
///
/// WebRTC's audio device module is ONE engine. Its `engineState` is a single
/// struct carrying `outputEnabled`, `outputRunning`, `inputEnabled` and
/// `inputRunning` together — playout and recording are two halves of one
/// AVAudioEngine, not two devices. So the output device's sample rate is the
/// engine's rate, and `OutputRateFollower` picking up a new one by stopping
/// and re-initialising playout restarts the graph the microphone feeds.
///
/// Pinning capture to the built-in microphone does not make it a separate
/// object. It only decides which device that one engine reads from. That is
/// how AirPods came to be implicated in a microphone fault on a Mac whose
/// microphone is not the AirPods: they are the only output here that changes
/// rate mid-session (48k A2DP down to 24k and back), so they are the only
/// output that makes this code restart the engine at all.
///
/// Measured, 27 Sep, one 76-second session: two rebuilds, after which the
/// transcriber received 41 seconds of audio and cut two sentences in half. The
/// panel gave no sign of it, which is the worse half — a microphone that stops
/// without saying so is indistinguishable from a person who has stopped
/// talking.
///
/// So the rebuild owns both halves, and this lives in Core rather than beside
/// the module because the rule it encodes is arithmetic about state, which a
/// test can hold, while the module needs a sound card.
public struct AudioEngineRebuild: Sendable {

    /// The six calls this needs from an audio device module, and the two flags
    /// it reads back. Exactly the shape of `LKRTCAudioDeviceModule`; named
    /// here so the decision below can be tested without one.
    public protocol Halves: AnyObject {
        var playing: Bool { get }
        var recording: Bool { get }
        func stopPlayout() -> Int
        func initPlayout() -> Int
        func startPlayout() -> Int
        func initRecording() -> Int
        func startRecording() -> Int
    }

    /// What one rebuild did, for the log and for a drill to read.
    public struct Outcome: Equatable, Sendable {
        public var stopped = 0, inited = 0, started = 0
        public var playing = false
        /// True when the microphone was running before the rebuild and was not
        /// after it. The whole reason this type exists.
        public var microphoneDropped = false
        /// Non-nil only when `microphoneDropped`: the re-arm's return codes.
        public var reInit: Int?
        public var reStart: Int?
        public var recording = false

        public var line: String {
            var s = "stop \(stopped), init \(inited), start \(started), "
                + "playing \(playing ? "yes" : "no")"
            if microphoneDropped {
                s += ", MICROPHONE DROPPED BY THE REBUILD, re-armed "
                    + "(init \(reInit ?? -1), start \(reStart ?? -1), "
                    + "recording \(recording ? "yes" : "no"))"
            } else {
                s += ", recording \(recording ? "yes" : "no")"
            }
            return s
        }
    }

    /// Stop, re-initialise and start playout, then put the microphone back if
    /// the restart took it.
    ///
    /// The before-reading is taken FIRST, deliberately: "the microphone was
    /// running and now is not" has to be a fact about this rebuild, not about
    /// the session. A microphone that was already off — the user stopped
    /// hands-free, the module is tearing down — must not be started here.
    @discardableResult
    public static func rebuild(_ adm: Halves) -> Outcome {
        var out = Outcome()
        let wasRecording = adm.recording
        out.stopped = adm.stopPlayout()
        out.inited = adm.initPlayout()
        out.started = adm.startPlayout()
        out.playing = adm.playing
        if wasRecording && !adm.recording {
            out.microphoneDropped = true
            out.reInit = adm.initRecording()
            out.reStart = adm.startRecording()
        }
        out.recording = adm.recording
        return out
    }
}
