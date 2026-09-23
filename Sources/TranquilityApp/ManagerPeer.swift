import AVFoundation
import Foundation
import LiveKitWebRTC
import TranquilityCore

/// Hands-free over WebRTC: the media path Pipecat prescribes for a device
/// client, and the one that lets the manager be interrupted.
///
/// The difference from `ManagerSocket` is not the wire, it is what the wire
/// brings. WebRTC carries echo cancellation, so the microphone reaching the
/// transcriber no longer contains the manager's own voice, so the bot no longer
/// has to feed its transcriber silence while it speaks, so a word said over the
/// manager is heard. Measured 22 Sep on the real acoustic path, laptop speakers
/// to built-in microphone: the bot spoke for eight seconds without hearing
/// itself, and "Stop" over it was transcribed, judged and acted on inside a
/// second. Noise suppression, gain control, a jitter buffer and reconnection
/// come with it.
///
/// Two things this class has to get right, both learned by measurement rather
/// than documentation:
///   - The audio device module must be `platformDefault`, the one that speaks
///     to the HAL. A factory built with no arguments enumerates no devices at
///     all, and then takes whatever the system default is, which is the AirPods
///     and the failure `AudioInputDevice.swift` exists to prevent.
///   - A running module will not change microphones underneath itself:
///     `trySetInputDevice` returns true and does nothing. Stop, set, start.
final class ManagerPeer: NSObject, ManagerTransport, @unchecked Sendable {
    typealias RequestHandler = @Sendable ([String]) async -> (code: Int, out: String)

    /// One signalling message, and its reply.
    ///
    /// Two callers, two roads. The dev shim posts straight at the host with a
    /// key of its own. The managed path goes through the Gateway, which
    /// carries the message because this Mac holds no vendor key and the host's
    /// endpoint refuses anything without one. The peer does not care which.
    typealias Signaller = @Sendable (_ method: String, _ body: [String: Any]) async throws -> [String: Any]
    private let signal: Signaller
    private let onRequest: RequestHandler
    /// Wire v1 (hf-3): announced with `hello` once a data channel is open.
    private let toolHost: ManagerToolHost?
    private let appVersion: String
    /// The channel `hello` last went out on; a new current channel gets its own.
    private weak var helloChannel: LKRTCDataChannel?
    private let factory: LKRTCPeerConnectionFactory
    private var connection: LKRTCPeerConnection?
    private var channel: LKRTCDataChannel?
    private var pcId: String?
    private var pendingCandidates: [LKRTCIceCandidate] = []
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?

    var onTrace: (@Sendable (String) -> Void)?

    init(signal: @escaping Signaller, toolHost: ManagerToolHost? = nil, appVersion: String = "",
         onRequest: @escaping RequestHandler) {
        self.signal = signal
        self.toolHost = toolHost
        self.appVersion = appVersion
        self.onRequest = onRequest
        LKRTCInitializeSSL()
        factory = LKRTCPeerConnectionFactory(
            audioDeviceModuleType: .platformDefault,
            bypassVoiceProcessing: false,
            encoderFactory: nil,
            decoderFactory: nil,
            audioProcessingModule: nil)
        super.init()
    }

    // MARK: - ManagerTransport

    func start() throws {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [LKRTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw ManagerSocketError.closed
        }
        connection = peer

        // The door channel: the same JSON the WebSocket carried, over the
        // data channel instead. The bot opens its own; ours is the fallback
        // for a bot that does not.
        let channelConfig = LKRTCDataChannelConfiguration()
        channelConfig.isOrdered = true
        channel = peer.dataChannel(forLabel: "tb", configuration: channelConfig)
        channel?.delegate = self

        let audio = LKRTCMediaConstraints(
            mandatoryConstraints: ["googEchoCancellation": "true",
                                   "googAutoGainControl": "true",
                                   "googNoiseSuppression": "true"],
            optionalConstraints: nil)
        let track = factory.audioTrack(with: factory.audioSource(with: audio), trackId: "mic0")
        peer.add(track, streamIds: ["tb"])
        peer.addTransceiver(of: .audio)

        peer.offer(for: constraints) { [weak self] offer, _ in
            guard let self, let offer else { return }
            peer.setLocalDescription(offer) { _ in self.post(offer) }
        }
    }

    /// A session that has not connected in this long is not going to. ICE
    /// gives up after fifteen seconds, and 23 Sep showed what that costs: two
    /// sessions landed on an instance that was being replaced, each sat the
    /// full fifteen seconds, and starting hands-free took twenty-two seconds
    /// instead of one. Failing fast turns a bad instance into a blink, because
    /// the reconnect path already tries again.
    static let connectDeadline: TimeInterval = 5

    private func armConnectDeadline() {
        let deadline = Self.connectDeadline
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard let self, self.connection?.connectionState != .connected,
                  self.connection != nil else { return }
            self.onTrace?("no connection in \(Int(deadline)) s; giving up on this session")
            await self.close()
        }
    }

    func lines() -> AsyncStream<Data> {
        AsyncStream { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
        }
    }

    func close() async {
        channel?.close()
        connection?.close()
        connection = nil
        takeContinuation()?.finish()
    }

    /// The microphone this Mac has chosen, not the system default.
    /// Called once audio is running, because the module lists no devices until
    /// then. Returns the name it settled on, for the log.
    @discardableResult
    func pinMicrophone(named wanted: String) -> String {
        let module = factory.audioDeviceModule
        guard let device = module.inputDevices.first(where: {
            $0.deviceId != "default" && $0.name == wanted
        }) else { return module.inputDevice.name }
        if module.inputDevice.deviceId == device.deviceId { return device.name }
        // Stop, set, start: a recording module ignores the setter and says it
        // succeeded (22 Sep).
        if module.recording { _ = module.stopRecording() }
        _ = module.trySetInputDevice(device)
        _ = module.initAndStartRecording()
        return module.inputDevice.name
    }

    var microphoneName: String { factory.audioDeviceModule.inputDevice.name }
    var echoCancellationIsActive: Bool {
        String(describing: factory.audioProcessingState.echoCancellation).contains("active:1")
    }

    /// Everything about the audio path in one line, because "echo cancellation
    /// on" was not enough: on 23 Sep the app reported it on and the manager
    /// still transcribed its own voice three seconds into its own sentence,
    /// while the same code in a command-line client cancelled eleven seconds
    /// of it cleanly. The difference has to be somewhere in here.
    var audioPathDescription: String {
        let adm = factory.audioDeviceModule
        let state = factory.audioProcessingState
        return "in=\(adm.inputDevice.name) [\(adm.inputDevice.deviceId)] "
            + "out=\(adm.outputDevice.name) [\(adm.outputDevice.deviceId)] "
            + "recording=\(adm.recording) playing=\(adm.playing) "
            + "echo=\(state.echoCancellation) ns=\(state.noiseSuppression)"
    }

    // MARK: - signalling

    private func post(_ offer: LKRTCSessionDescription) {
        // The description itself is not Sendable; its text is.
        let sdp = offer.sdp
        Task { [weak self] in
            guard let self else { return }
            do {
                let obj = try await self.signal("POST", ["sdp": sdp, "type": "offer"])
                guard let answer = obj["sdp"] as? String else {
                    self.onTrace?("offer refused: no sdp in the answer")
                    self.takeContinuation()?.finish()
                    return
                }
                self.pcId = obj["pc_id"] as? String
                self.onTrace?("answered, \(answer.count) bytes")
                self.connection?.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: answer)) { _ in
                    self.flushCandidates()
                    self.armConnectDeadline()
                }
            } catch {
                self.onTrace?("offer refused: \(error)")
                self.takeContinuation()?.finish()
            }
        }
    }

    private func flushCandidates() {
        lock.lock()
        guard let pcId, !pendingCandidates.isEmpty else { lock.unlock(); return }
        let candidates = pendingCandidates.map { [
            "candidate": $0.sdp, "sdp_mid": $0.sdpMid ?? "0", "sdp_mline_index": $0.sdpMLineIndex,
        ] as [String: Any] }
        pendingCandidates.removeAll()
        lock.unlock()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.signal("PATCH", ["pc_id": pcId, "candidates": candidates])
                self.onTrace?("sent \(candidates.count) candidate(s)")
            } catch {
                // Trickled candidates are an optimisation, not the connection:
                // the offer already carried everything gathered before it.
                self.onTrace?("candidates refused: \(error)")
            }
        }
    }

    /// A door's answer, back the way the request came.
    func send(_ payload: Data) {
        lock.lock(); let channel = self.channel; lock.unlock()
        channel?.sendData(LKRTCDataBuffer(data: payload, isBinary: false))
    }

    private func takeContinuation() -> AsyncStream<Data>.Continuation? {
        lock.lock(); defer { lock.unlock() }
        let c = continuation; continuation = nil; return c
    }
    private func currentContinuation() -> AsyncStream<Data>.Continuation? {
        lock.lock(); defer { lock.unlock() }; return continuation
    }
}

// MARK: - the bot's lines and its door requests

extension ManagerPeer: LKRTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        onTrace?("data channel \(dataChannel.label): \(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .open { sendHello(on: dataChannel) }
    }

    /// `hello` (what this Mac offers) on each channel that is current and
    /// open. Ours can open before the bot opens its own and becomes the one
    /// we send on; the bot keeps the latest hello, so a second is harmless and
    /// a missing one would leave it on `request:run`.
    private func sendHello(on dataChannel: LKRTCDataChannel) {
        lock.lock()
        let due = toolHost != nil && dataChannel === channel && helloChannel !== dataChannel
        if due { helloChannel = dataChannel }
        lock.unlock()
        guard due, let toolHost else { return }
        let version = appVersion
        Task { [weak self] in
            let hello = await toolHost.hello(appVersion: version)
            self?.send(hello)
            self?.onTrace?("hello sent (\(hello.count)b)")
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        let data = buffer.data
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if obj["wire"] is String {
            guard let toolHost else { return }
            onTrace?("frame wire:\(obj["wire"] as? String ?? "?") \(data.count)b")
            Task { [weak self] in
                guard let reply = await toolHost.handle(data) else { return }
                self?.send(reply)
            }
            return
        }
        if obj["request"] as? String == "run", let id = obj["id"] as? String,
           let argv = obj["argv"] as? [String] {
            onTrace?("frame request:run \(data.count)b")
            let handler = onRequest
            let started = Date()
            Task { [weak self] in
                let (code, out) = await handler(argv)
                // `type` is not decoration: the bot's data channel reads
                // `json_message["type"]` on every message and throws away
                // anything without one ("Error parsing JSON message",
                // connection.py:365). Our replies had no type, so every door
                // answer was discarded and every invite timed out after 45 s
                // (23 Sep). Anything but "signalling", which is reserved.
                guard let payload = try? JSONSerialization.data(withJSONObject: [
                    "type": "tb", "reply": id, "code": code, "out": out,
                ] as [String: Any]) else { return }
                self?.send(payload)
                self?.onTrace?("answered \(argv.prefix(2).joined(separator: " ")) -> \(code) "
                               + "in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
            return
        }
        // Only the manager's own lines go on. A WebRTC data channel also
        // carries the framework's RTVI traffic, which is not ours to read: it
        // reached the viewer as rows of "Invalid" with undefined fields
        // (23 Sep), because the WebSocket serializer had never passed anything
        // but our lines and everything downstream assumed that.
        guard let kind = obj["event"] as? String else {
            onTrace?("ignored a \(obj["type"] as? String ?? "framework") message, \(data.count)b")
            return
        }
        onTrace?("frame \(kind) \(data.count)b")
        currentContinuation()?.yield(data)
    }
}

extension ManagerPeer: LKRTCPeerConnectionDelegate {
    func peerConnection(_ pc: LKRTCPeerConnection, didChange state: LKRTCPeerConnectionState) {
        onTrace?("connection \(state.rawValue)")
        if state == .failed || state == .closed { takeContinuation()?.finish() }
    }
    func peerConnection(_ pc: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        lock.lock(); pendingCandidates.append(candidate); lock.unlock()
        flushCandidates()
    }
    func peerConnection(_ pc: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        onTrace?("bot opened the data channel: \(dataChannel.label)")
        channel = dataChannel
        dataChannel.delegate = self
        if dataChannel.readyState == .open { sendHello(on: dataChannel) }
    }
    func peerConnectionShouldNegotiate(_ pc: LKRTCPeerConnection) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
}
