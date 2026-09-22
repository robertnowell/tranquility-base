import AVFoundation
import Foundation

/// The hosted manager on the other end of one WebSocket.
///
/// Ruled 21 Sep: the hands-free manager runs where we host it (Pipecat Cloud
/// first, our own machines behind the same seam), unchanged, and the app
/// speaks to it over a single socket. Binary frames are audio: PCM16 mono,
/// 16 kHz up from the microphone, 24 kHz down from the synthesizer. Text
/// frames are the JSON lines the orb already parses (`ManagerEvent`), plus
/// one request/reply pair, because a hosted bot has no `tbase` and no deep
/// links where it runs:
///
///     down  {"request":"run","id":"r1","argv":["tbase","targets","--json"]}
///     up    {"reply":"r1","code":0,"out":"[...]"}
///
/// The app answers a `run` request by doing what the local child would have
/// done itself. This class does not know what a session costs or who started
/// it: it is handed a URL and a token (`ManagerSession`) and speaks. Where
/// the session comes from (the Gateway, or the dev shim in `hq.json`) is
/// `ManagerSessionStarter`'s business.
///
/// It presents the same surface as `ACPProcessTransport`, `lines()` and
/// `close()`, so the app's manager loop is the same code for a local child
/// and a hosted one.
public struct ManagerSession: Sendable, Equatable {
    public let url: URL
    public let token: String?
    public let sessionId: String?
    public init(url: URL, token: String?, sessionId: String? = nil) {
        self.url = url; self.token = token; self.sessionId = sessionId
    }
}

/// Where the microphone audio comes from. The real one is an AUHAL capture
/// unit converted to 16 kHz PCM16; a drill hands in a WAV so the socket can
/// be proven without a room.
public protocol ManagerAudioSource: AnyObject {
    func start(onPCM16: @escaping @Sendable (Data) -> Void) throws
    func stop()
}

/// The microphone as the manager hears it: the chosen input device, at the
/// hardware rate, converted to 16 kHz mono PCM16 exactly as `Recorder` does
/// for dictation, but on its own capture unit so hands-free and a chord
/// dictation never fight over one stream.
public final class ManagerMicrophone: ManagerAudioSource {
    private var unit: CaptureUnit?
    private var converter: StreamingPCM16Converter?
    public init() {}

    public func start(onPCM16: @escaping @Sendable (Data) -> Void) throws {
        guard let device = AudioInputDevice.resolve() ?? AudioInputDevice.allInputs().first else {
            throw ManagerSocketError.noInputDevice
        }
        let unit = try CaptureUnit(deviceID: device.id) { [weak self] buffer in
            guard let self else { return }
            if self.converter == nil {
                self.converter = StreamingPCM16Converter(from: buffer.format)
            }
            if let data = self.converter?.convert(buffer), !data.isEmpty { onPCM16(data) }
        }
        try unit.start()
        self.unit = unit
    }

    public func stop() {
        unit?.stop(); unit?.dispose(); unit = nil; converter = nil
    }
}

/// The manager's voice: 24 kHz PCM16 down the wire, scheduled onto a player
/// node as it arrives. `flush` drops what has not played yet, which is how an
/// interruption sounds like one.
open class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var started = false

    public init(sampleRate: Double = 24_000) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    open func play(_ pcm16: Data) {
        lock.lock(); defer { lock.unlock() }
        if !started {
            do { try engine.start() } catch { return }
            node.play()
            started = true
        }
        let frames = pcm16.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let dst = buffer.floatChannelData![0]
            for i in 0..<frames { dst[i] = Float(src[i]) / 32768 }
        }
        node.scheduleBuffer(buffer)
    }

    open func flush() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        node.stop(); node.play()
    }

    open func stop() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        node.stop(); engine.stop(); started = false
    }
}

public enum ManagerSocketError: Error, Equatable {
    case noInputDevice
    case closed
}

public final class ManagerSocket: @unchecked Sendable {
    public typealias RequestHandler = @Sendable ([String]) async -> (code: Int, out: String)

    private let session: ManagerSession
    private let audio: ManagerAudioSource
    private let player: PCMPlayer?
    private let onRequest: RequestHandler
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var outgoing = Data()
    /// 20 ms of 16 kHz PCM16: the frame size the bot's VAD likes.
    private let chunk = 640
    public private(set) var closeReason: String?
    /// Microphone level, once every two seconds of audio sent: the proof that
    /// the room reaches the wire. 02:15, 22 Sep: 106 s of audio arrived at the
    /// STT and transcribed to nothing, and the log could not say whether that
    /// was silence in the room or silence on the wire.
    public var onLevel: (@Sendable (Float, Int) -> Void)?
    private var levelAccum: (sumSquares: Double, samples: Int, sentBytes: Int) = (0, 0, 0)

    public init(session: ManagerSession, audio: ManagerAudioSource, player: PCMPlayer? = PCMPlayer(),
                onRequest: @escaping RequestHandler) {
        self.session = session
        self.audio = audio
        self.player = player
        self.onRequest = onRequest
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        urlSession = URLSession(configuration: config)
    }

    /// Connect, open the microphone, and start receiving. Lines arrive on
    /// `lines()`; audio plays as it comes; requests are answered in place.
    public func start() throws {
        var request = URLRequest(url: session.url)
        if let token = session.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = urlSession.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiver = Task { [weak self] in await self?.receiveLoop(task) }
        try audio.start { [weak self] pcm in self?.send(pcm) }
    }

    /// Every text frame that is not a reply or a request: the event lines.
    public func lines() -> AsyncStream<Data> {
        AsyncStream { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
        }
    }

    public func close() async {
        audio.stop()
        player?.stop()
        receiver?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        takeContinuation()?.finish()
    }

    /// The locks are plain NSLocks used from async code only through these
    /// two synchronous helpers, which is the scoped form Swift 6 asks for.
    private func takeContinuation() -> AsyncStream<Data>.Continuation? {
        lock.lock(); defer { lock.unlock() }
        let c = continuation; continuation = nil; return c
    }

    private func currentContinuation() -> AsyncStream<Data>.Continuation? {
        lock.lock(); defer { lock.unlock() }
        return continuation
    }

    // MARK: - up

    private func send(_ pcm16: Data) {
        lock.lock()
        pcm16.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) { let f = Double(v) / 32768; levelAccum.sumSquares += f * f }
        }
        levelAccum.samples += pcm16.count / 2
        levelAccum.sentBytes += pcm16.count
        var report: (Float, Int)?
        if levelAccum.samples >= 32_000 {
            report = (Float((levelAccum.sumSquares / Double(levelAccum.samples)).squareRoot()), levelAccum.sentBytes)
            levelAccum = (0, 0, levelAccum.sentBytes)
        }
        outgoing.append(pcm16)
        var frames: [Data] = []
        while outgoing.count >= chunk {
            frames.append(outgoing.prefix(chunk))
            outgoing.removeFirst(chunk)
        }
        let task = self.task
        lock.unlock()
        if let report { onLevel?(report.0, report.1) }
        guard let task else { return }
        for frame in frames {
            task.send(.data(frame)) { _ in }
        }
    }

    private func sendText(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    // MARK: - down

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let pcm): player?.play(pcm)
                case .string(let text): await handle(text: text)
                @unknown default: break
                }
            } catch {
                closeReason = error.localizedDescription
                break
            }
        }
        takeContinuation()?.finish()
    }

    private func handle(text: String) async {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let kind = obj["request"] as? String, let id = obj["id"] as? String {
            guard kind == "run", let argv = obj["argv"] as? [String], !argv.isEmpty else {
                sendText(["reply": id, "code": 2, "out": "unknown request"])
                return
            }
            let (code, out) = await onRequest(argv)
            sendText(["reply": id, "code": code, "out": out])
            return
        }
        // An event line. Interruptions are the manager going quiet: drop what
        // has not played so a cut sounds like a cut.
        if (obj["event"] as? String) == "quiet" { player?.flush() }
        currentContinuation()?.yield(data)
    }
}

/// Where a session comes from. Today: the dev shim in `~/.claude/hq.json`
/// (`manager.hosted.start`, a Pipecat Cloud start URL, and
/// `manager.hosted.key`, a public API key) on the developer's own Mac.
/// Tomorrow: the Gateway, with the signed-in device's bearer, which is the
/// only way another user's Mac ever gets a session (hands-free-on-the-gateway,
/// 21 Sep). The shim is deliberately not a Secrets key: it must not outlive
/// the Gateway route.
public enum ManagerSessionStarter {
    public struct Hosted: Equatable, Sendable {
        public let start: URL
        public let key: String
    }

    public static func hosted(config: URL = HubApp.configPath) -> Hosted? {
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manager = obj["manager"] as? [String: Any],
              let hosted = manager["hosted"] as? [String: Any],
              let start = (hosted["start"] as? String).flatMap(URL.init(string:)),
              let key = hosted["key"] as? String, !key.isEmpty else { return nil }
        return Hosted(start: start, key: key)
    }

    /// `POST /start` with `transport: websocket`: the bot starts when we connect.
    /// `keyterms` ride in the session body (the fleet's names, so the STT can
    /// spell them); the service hands the body back encoded and it is appended
    /// to the socket URL, which is how Pipecat Cloud carries it.
    public static func start(_ hosted: Hosted, keyterms: [String] = []) async throws -> ManagerSession {
        var request = URLRequest(url: hosted.start)
        request.httpMethod = "POST"
        request.setValue("Bearer \(hosted.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["transport": "websocket"]
        if !keyterms.isEmpty { payload["body"] = ["keyterms": Array(keyterms.prefix(80))] }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var ws = (obj["wsUrl"] as? String).flatMap(URL.init(string:)) else {
            throw ManagerSocketError.closed
        }
        if let encoded = obj["body"] as? String, !encoded.isEmpty,
           var parts = URLComponents(url: ws, resolvingAgainstBaseURL: false) {
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "body", value: encoded)]
            if let u = parts.url { ws = u }
        }
        return ManagerSession(url: ws, token: obj["token"] as? String, sessionId: obj["sessionId"] as? String)
    }
}
