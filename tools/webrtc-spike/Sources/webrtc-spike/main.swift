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
        factory = LKRTCPeerConnectionFactory(
            audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: false,
            encoderFactory: nil,
            decoderFactory: nil,
            audioProcessingModule: nil)
        super.init()
    }

    /// Question one: can we name the microphone, rather than taking whatever
    /// the system default is? Our device policy exists because the default is
    /// the AirPods, and opening their microphone drags the link into HFP.
    func chooseMicrophone(_ when: String) {
        let adm = factory.audioDeviceModule
        print("WebRTC input devices (\(when)), recording=\(adm.recording):")
        print("   processing: echo=\(factory.audioProcessingState.echoCancellation), ns=\(factory.audioProcessingState.noiseSuppression)")
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
        print(adm.inputDevice.deviceId == builtIn.deviceId
              ? "   PINNED by identity, not following the default"
              : "   NOT PINNED: still on \(adm.inputDevice.deviceId)")
    }

    func start() {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [LKRTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
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

print("system default input: \(systemDefaultInputName())")
let spike = Spike()
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
