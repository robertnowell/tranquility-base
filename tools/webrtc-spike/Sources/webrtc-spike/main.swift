import AVFoundation
import CoreAudio
import Foundation
import LiveKitWebRTC

// Usage: webrtc-spike <offer-url>            e.g. http://localhost:7864/api/offer

let offerURL = URL(string: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
                                                           : "http://localhost:7864/api/offer")!
/// Pipecat Cloud wants the public key on the session's offer route; localhost
/// wants nothing.
let bearer: String? = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

/// The built-in microphone by transport type, not by name or by the default.
func builtInMicrophoneID() -> AudioDeviceID? {
    var size = UInt32(0)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids {
        var transport = UInt32(0)
        var tsize = UInt32(MemoryLayout<UInt32>.size)
        var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { continue }
        var streams = UInt32(0)
        var saddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                               mScope: kAudioDevicePropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &streams) == noErr, streams > 0 else { continue }
        return id
    }
    return nil
}

func defaultOutputID() -> AudioDeviceID {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
    return id
}

func defaultOutputRate() -> Double {
    var r = Double(0)
    var size = UInt32(MemoryLayout<Double>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(defaultOutputID(), &a, 0, nil, &size, &r)
    return r
}

func systemDefaultInputName() -> String {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
    var name: CFString = "" as CFString
    size = UInt32(MemoryLayout<CFString>.size)
    address.mSelector = kAudioDevicePropertyDeviceNameCFString
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
    return name as String
}

final class Spike: NSObject, LKRTCPeerConnectionDelegate {
    let factory: LKRTCPeerConnectionFactory
    var connection: LKRTCPeerConnection?
    var pcId: String?
    let done = DispatchSemaphore(value: 0)
    var sawConnected = false
    var remoteAudio: LKRTCAudioTrack?
    var posted = false
    var pending: [LKRTCIceCandidate] = []
    var sentBytes = 0.0
    var receivedBytes = 0.0

    override init() {
        LKRTCInitializeSSL()
        // The platform-default module is the one that speaks to the HAL on
        // macOS, and the HAL is where device identity lives. A factory built
        // with no arguments enumerated nothing at all.
        // TB_ENGINE_ADM switches to the audio-engine module, the one whose
        // delegate hands us the live AVAudioEngine. That is the only way the
        // app's own voice can join the render graph the canceller references,
        // which is the point: a canceller should never have to be told not to
        // listen. The question this spike answers is whether that module can
        // still name a microphone, because the platform-default one can and
        // our device policy depends on it.
        let bypassVP = ProcessInfo.processInfo.environment["TB_BYPASS_VP"] != nil
        print("platform voice processing: \(bypassVP ? "BYPASSED (software AEC3)" : "on")")
        let engineADM = ProcessInfo.processInfo.environment["TB_ENGINE_ADM"] != nil
        print("audio device module: \(engineADM ? "audioEngine" : "platformDefault")")
        factory = LKRTCPeerConnectionFactory(
            audioDeviceModuleType: engineADM ? .audioEngine : .platformDefault,
            bypassVoiceProcessing: bypassVP,
            encoderFactory: nil,
            decoderFactory: nil,
            audioProcessingModule: nil)
        super.init()
        factory.audioDeviceModule.observer = self
    }

    /// Question one: can we name the microphone, rather than taking whatever
    /// the system default is? Our device policy exists because the default is
    /// the AirPods, and opening their microphone drags the link into HFP.
    func chooseMicrophone(_ when: String) {
        if ProcessInfo.processInfo.environment["TB_NO_PIN"] != nil {
            print("not pinning: leaving the module on its own device")
            let adm = factory.audioDeviceModule
            print("   current: \(adm.inputDevice.name) [\(adm.inputDevice.deviceId)]")
            print("   processing: \(factory.audioProcessingState.echoCancellation)")
            return
        }
        let adm = factory.audioDeviceModule
        print("WebRTC input devices (\(when)), recording=\(adm.recording):")
        print("   processing: echo=\(factory.audioProcessingState.echoCancellation), ns=\(factory.audioProcessingState.noiseSuppression)")
        print("   playout: \(adm.outputDevice.name) [\(adm.outputDevice.deviceId)] playing=\(adm.playing)")
        print("   system default output: \(defaultOutputID()) at \(defaultOutputRate()) Hz")
        for d in adm.outputDevices { print("   out: \(d.name)  [\(d.deviceId)]") }
        if let want = ProcessInfo.processInfo.environment["TB_PIN_OUT"],
           let device = adm.outputDevices.first(where: { $0.deviceId == want }) {
            let ok = adm.trySetOutputDevice(device)
            print("   trySetOutputDevice(\(device.name) [\(device.deviceId)]) -> \(ok)")
            print("   now: \(adm.outputDevice.name) [\(adm.outputDevice.deviceId)], device rate \(defaultOutputRate()) Hz")
        }
        for device in adm.inputDevices { print("   \(device.name)  [\(device.deviceId)]") }
        print("   current: \(adm.inputDevice.name)")
        if adm.inputDevices.isEmpty {
            // Nothing listed: is the module simply not started, or is this
            // binary not allowed a microphone at all? A bare command-line tool
            // has no bundle identifier, so it cannot hold a TCC grant.
            let started = adm.initAndStartRecording()
            print("   initAndStartRecording -> \(started), recording=\(adm.recording), now \(adm.inputDevices.count) device(s)")
            for device in adm.inputDevices { print("   \(device.name)  [\(device.deviceId)]") }
        }
        // Explicitly NOT the "default" pseudo-device: the whole point is to
        // pin a device by identity, the way CaptureUnit does, so that what the
        // system default happens to be cannot move the microphone under us.
        guard let builtIn = adm.inputDevices.first(where: {
            $0.deviceId != "default"
                && ($0.name.localizedCaseInsensitiveContains("macbook")
                    || $0.name.localizedCaseInsensitiveContains("built-in"))
        }) else {
            print("   NO built-in microphone in the list")
            return
        }
        let ok = adm.trySetInputDevice(builtIn)
        print("   trySetInputDevice(\(builtIn.name) [\(builtIn.deviceId)]) -> \(ok)")
        print("   now: \(adm.inputDevice.name) [\(adm.inputDevice.deviceId)]")
        // The property form, in case the try- variant does not stick the
        // selection when the module is already running.
        adm.inputDevice = builtIn
        print("   after assigning the property: \(adm.inputDevice.name) [\(adm.inputDevice.deviceId)]")
        if adm.inputDevice.deviceId != builtIn.deviceId, adm.recording {
            // A running module will not change microphones underneath itself.
            // Stopping, choosing, and starting again is the sequence an app
            // uses when someone picks a different input.
            let stopped = adm.stopRecording()
            let set = adm.trySetInputDevice(builtIn)
            let started = adm.initAndStartRecording()
            print("   stop(\(stopped)) set(\(set)) start(\(started)) -> \(adm.inputDevice.name) [\(adm.inputDevice.deviceId)]")
        }
        print("   processing after the pin: echo=\(factory.audioProcessingState.echoCancellation)")
        print(adm.inputDevice.deviceId == builtIn.deviceId
              ? "   PINNED by identity, not following the default"
              : "   NOT PINNED: still on \(adm.inputDevice.deviceId)")
    }

    func start() {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        // TB_ICE_SERVERS is the same JSON a relay's credential API answers
        // with, so the spike can be pointed at exactly what the app will use.
        // TB_RELAY_ONLY then refuses every direct path, which is the only way
        // to prove a relay works: leave both policies open and the connection
        // succeeds directly and tells you nothing.
        let env = ProcessInfo.processInfo.environment
        if let raw = env["TB_ICE_SERVERS"], let data = raw.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            config.iceServers = list.compactMap { entry in
                let urls = (entry["urls"] as? [String]) ?? (entry["urls"] as? String).map { [$0] }
                guard let urls else { return nil }
                return LKRTCIceServer(urlStrings: urls,
                                      username: entry["username"] as? String,
                                      credential: entry["credential"] as? String)
            }
            let relays = list.filter { entry in
                let urls = (entry["urls"] as? [String]) ?? (entry["urls"] as? String).map { [$0] } ?? []
                return urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
            }
            print("ice: \(config.iceServers.count) server(s), \(relays.count) that can relay")
        } else {
            config.iceServers = [LKRTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
            print("ice: the shipped stun server, which cannot relay")
        }
        if env["TB_RELAY_ONLY"] != nil {
            config.iceTransportPolicy = .relay
            print("ice: RELAY ONLY — a direct path is refused, so connecting proves the relay")
        }
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            print("no peer connection"); exit(1)
        }
        connection = pc

        // Echo cancellation lives here: the audio source's constraints are what
        // switch on the engine's processing.
        let audioConstraints = LKRTCMediaConstraints(
            mandatoryConstraints: ["googEchoCancellation": "true",
                                   "googAutoGainControl": "true",
                                   "googNoiseSuppression": "true"],
            optionalConstraints: nil)
        let source = factory.audioSource(with: audioConstraints)
        let track = factory.audioTrack(with: source, trackId: "mic0")
        pc.add(track, streamIds: ["tb"])
        pc.addTransceiver(of: .audio)

        pc.offer(for: constraints) { [weak self] offer, error in
            guard let self, let offer else { print("offer failed: \(error as Any)"); exit(1) }
            // Wait for gathering to finish and post the description WITH its
            // candidates. Pipecat's offer route takes one shot: there is a
            // PATCH for trickle, but a complete offer needs no second round,
            // and against the cloud agent an offer with no candidates never
            // connected at all (0 bytes, 22 Sep).
            pc.setLocalDescription(offer) { _ in self.post(offer) }
        }
    }

    func post(_ offer: LKRTCSessionDescription) {
        var request = URLRequest(url: offerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "sdp": offer.sdp, "type": "offer",
        ])
        print("posting offer to \(offerURL) (\(offer.sdp.count) bytes)")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sdp = obj["sdp"] as? String else {
                print("answer refused: \(status) \(error as Any) \(String(data: data ?? Data(), encoding: .utf8) ?? "")")
                self.done.signal(); return
            }
            self.pcId = obj["pc_id"] as? String
            print("answer: \(status), pc_id=\(self.pcId ?? "-"), \(sdp.count) bytes")
            self.flushCandidates()
            let answer = LKRTCSessionDescription(type: .answer, sdp: sdp)
            self.connection?.setRemoteDescription(answer) { error in
                print("remote description set: \(error == nil ? "ok" : String(describing: error))")
            }
        }.resume()
    }

    // MARK: - delegate
    func peerConnection(_ pc: LKRTCPeerConnection, didChange state: LKRTCPeerConnectionState) {
        print("connection state: \(state.rawValue) \(state == .connected ? "CONNECTED" : "")")
        if state == .connected { sawConnected = true }
        if state == .failed || state == .closed { done.signal() }
    }
    func peerConnection(_ pc: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {
        print("receiving a track: \(rtpReceiver.track?.kind ?? "?")")
        if let track = rtpReceiver.track as? LKRTCAudioTrack {
            remoteAudio = track
            track.isEnabled = true
        }
    }

    /// Ask the connection what actually crossed it. Bytes received on the
    /// audio track is the difference between "connected" and "it works".
    func report() {
        guard let pc = connection else { return }
        pc.statistics { report in
            var sent = 0.0, received = 0.0, heardLevel = 0.0
            for (_, stat) in report.statistics {
                guard stat.type == "outbound-rtp" || stat.type == "inbound-rtp" || stat.type == "media-source" else { continue }
                if let kind = stat.values["kind"] as? String, kind != "audio" { continue }
                if stat.type == "outbound-rtp", let bytes = stat.values["bytesSent"] as? NSNumber { sent = bytes.doubleValue }
                if stat.type == "inbound-rtp", let bytes = stat.values["bytesReceived"] as? NSNumber { received = bytes.doubleValue }
                if stat.type == "media-source", let level = stat.values["audioLevel"] as? NSNumber { heardLevel = level.doubleValue }
            }
            print(String(format: "audio: %.0f bytes up, %.0f bytes down, microphone level %.4f", sent, received, heardLevel))
            print("   echo=\(self.factory.audioProcessingState.echoCancellation) in=\(self.factory.audioDeviceModule.inputDevice.deviceId) out=\(self.factory.audioDeviceModule.outputDevice.deviceId)")
            print(String(format: "   OUTPUT DEVICE %d IS RUNNING AT %.0f Hz", defaultOutputID(), defaultOutputRate()))
            self.sentBytes = sent; self.receivedBytes = received
        }
    }
    func peerConnectionShouldNegotiate(_ pc: LKRTCPeerConnection) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        print("ice: \(newState.rawValue)")
    }
    func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        print("ice gathering: \(newState.rawValue)")
    }
    /// Trickle: the offer goes out at once and candidates follow as they are
    /// found. Waiting for gathering to finish took 35 s against the cloud
    /// agent, which is longer than a session waits (22 Sep).
    func peerConnection(_ pc: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        pending.append(candidate)
        flushCandidates()
    }

    func flushCandidates() {
        guard let pcId, !pending.isEmpty else { return }
        let candidates = pending.map { [
            "candidate": $0.sdp,
            "sdp_mid": $0.sdpMid ?? "0",
            "sdp_mline_index": $0.sdpMLineIndex,
        ] as [String: Any] }
        pending.removeAll()
        var request = URLRequest(url: offerURL)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["pc_id": pcId, "candidates": candidates])
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("sent \(candidates.count) candidate(s) -> \(status)")
        }.resume()
    }
    func peerConnection(_ pc: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        print("data channel open: \(dataChannel.label)")
    }
}

extension Spike: LKRTCAudioDeviceModuleDelegate {
    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, didReceiveSpeechActivityEvent e: LKRTCSpeechActivityEvent) {}
    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int {
        print("ADM: didCreateEngine")
        pinEngineInput(engine)
        return 0
    }
    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool,
                           isVoiceProcessingEnabled: Bool) -> Int {
        print("ADM: willEnableEngine playout=\(isPlayoutEnabled) recording=\(isRecordingEnabled) vpio=\(isVoiceProcessingEnabled)")
        return 0
    }
    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int { 0 }
    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int { 0 }
    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureInputFromSource src: AVAudioNode?, toDestination dst: AVAudioNode,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        print("ADM: configureInput  src=\(src.map { String(describing: type(of: $0)) } ?? "nil") dst=\(type(of: dst))")
        pinEngineInput(engine)
        return 0
    }

    /// The audio-engine module will not take a device through `trySetInputDevice`
    /// — it returns false and the property reads empty. The engine's own input
    /// unit will, which is the ordinary macOS way to choose a capture device,
    /// and this is the hook that hands us the engine.
    func pinEngineInput(_ engine: AVAudioEngine) {
        guard let want = builtInMicrophoneID() else { print("   pin: no built-in microphone"); return }
        let unit = engine.inputNode.auAudioUnit
        let before = (try? unit.deviceID) ?? 0
        do {
            try unit.setDeviceID(want)
            print("   pin: input unit \(before) -> \(unit.deviceID) (wanted \(want)) \(unit.deviceID == want ? "PINNED" : "NOT PINNED")")
        } catch {
            print("   pin: setDeviceID(\(want)) threw \(error)")
        }
    }
    func audioDeviceModule(_ m: LKRTCAudioDeviceModule, engine: AVAudioEngine,
                           configureOutputFromSource src: AVAudioNode, toDestination dst: AVAudioNode?,
                           format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        print("ADM: configureOutput src=\(type(of: src)) dst=\(dst.map { String(describing: type(of: $0)) } ?? "nil") format=\(format)")
        // THE POINT: mix our own player into the graph the canceller references.
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: dst ?? engine.mainMixerNode, format: format)
        engine.connect(src, to: dst ?? engine.mainMixerNode, format: format)
        print("ADM: attached a player node beside the connection's own output -> \(dst.map { String(describing: type(of: $0)) } ?? "mainMixer")")
        return 0
    }
    func audioDeviceModuleDidUpdateDevices(_ m: LKRTCAudioDeviceModule) {}
}

/// Follow the device's rate instead of trusting the one it had when we started.
///
/// A Bluetooth headset renegotiates when a duplex path opens: the AirPods drop
/// to 24 kHz for the transition and come back to 48 kHz, and whatever read the
/// rate during that window is now rendering at half speed's worth of samples
/// into a device running twice as fast. TB_FOLLOW_RATE re-initialises playout
/// once the rate has settled.
final class RateWatcher {
    private let adm: LKRTCAudioDeviceModule
    private var pending: DispatchWorkItem?
    private var lastSeen: Double = 0

    init(adm: LKRTCAudioDeviceModule) {
        self.adm = adm
        lastSeen = defaultOutputRate()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let me = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(defaultOutputID(), &address, { _, _, _, ctx in
            guard let ctx else { return noErr }
            Unmanaged<RateWatcher>.fromOpaque(ctx).takeUnretainedValue().changed()
            return noErr
        }, me)
    }

    private func changed() {
        let now = defaultOutputRate()
        print(String(format: "   rate changed: %.0f -> %.0f Hz", lastSeen, now))
        lastSeen = now
        // Bluetooth fires several of these in a burst; act once it settles.
        pending?.cancel()
        let work = DispatchWorkItem { [adm] in
            let settled = defaultOutputRate()
            print(String(format: "   settled at %.0f Hz; re-initialising playout", settled))
            print("   stopPlayout=\(adm.stopPlayout()) initPlayout=\(adm.initPlayout()) startPlayout=\(adm.startPlayout()) playing=\(adm.playing)")
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

print("system default input: \(systemDefaultInputName())")
let spike = Spike()
var watcher: RateWatcher?
if ProcessInfo.processInfo.environment["TB_FOLLOW_RATE"] != nil {
    watcher = RateWatcher(adm: spike.factory.audioDeviceModule)
    print("following the output device's rate")
}
spike.chooseMicrophone("before")
spike.start()
DispatchQueue.global().asyncAfter(deadline: .now() + 6) { spike.chooseMicrophone("once running") }
for seconds in [14, 22, 30, 38] {
    DispatchQueue.global().asyncAfter(deadline: .now() + Double(seconds)) { spike.report() }
}
_ = spike.done.wait(timeout: .now() + 42)
Thread.sleep(forTimeInterval: 1)
print(spike.sawConnected ? "SPIKE: connected" : "SPIKE: did not connect")
print(spike.sentBytes > 1000 && spike.receivedBytes > 1000
      ? "SPIKE: audio crossed in both directions"
      : "SPIKE: audio did not cross (up \(Int(spike.sentBytes)), down \(Int(spike.receivedBytes)))")
