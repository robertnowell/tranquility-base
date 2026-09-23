import Foundation
import CryptoKit

/// Hearing and speaking, bought with the sign-in rather than with keys.
///
/// Summaries went through the Gateway first, then hands-free; these are the
/// other two things a person pays for. Until now the premium voice needed an
/// ElevenLabs account of their own and the live transcript an AssemblyAI one,
/// so somebody could sign in, hold ten dollars of credit, and still be told
/// to go and open two accounts before the app would say anything.
///
/// Both are the same shape as everything else managed: the Gateway holds the
/// vendor key, charges this account, and hands back exactly what the app
/// needs — a clip, or a token for one socket. Neither the key nor (for the
/// transcript) the audio passes through anything of ours.

// MARK: - The voice

public struct GatewaySpeechClip: Decodable, Sendable {
    public let audioBase64: String
    public let characterStartTimes: [Double]?
    public let characters: Int
}

struct GatewaySpeechResult: Decodable, Sendable {
    let version: String
    let kind: String
    let accountId: String
    let operationId: String
    let state: String
    let characters: Int?
    let clip: GatewaySpeechClip?
    let error: GatewayOperation.ServiceError?
}

public struct ManagedSpeechClient: Sendable {
    public let accountId: UUID
    public let transport: any GatewayTransport
    public init(accountId: UUID, transport: any GatewayTransport) {
        self.accountId = accountId; self.transport = transport
    }

    /// One line, bought once.
    ///
    /// The clip id is derived from the words and the voice, so the same line
    /// asked for twice is the same operation: the Gateway answers the second
    /// time with the receipt and no audio, and the caller must already have
    /// kept the sound — which the app's clip cache does.
    public func speak(_ text: String, voice: String?) async throws -> SpokenClip {
        let id = Self.clipId(text: text, voice: voice, account: accountId)
        var payload: [String: Any] = ["version": "1", "text": text]
        if let voice { payload["voice"] = voice }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let response = try await transport.request(
            method: "PUT", path: "/v1/accounts/\(accountId.uuidString.lowercased())/speech/\(id.uuidString.lowercased())",
            body: body)
        guard response.status == 200 else {
            struct Envelope: Decodable { let error: GatewayOperation.ServiceError }
            let code = (try? JSONDecoder().decode(Envelope.self, from: response.body))?.error.code ?? "service_unavailable"
            throw ManagedSummaryFailure.refused(code: code, operationId: id.uuidString.lowercased())
        }
        let result = try JSONDecoder().decode(GatewaySpeechResult.self, from: response.body)
        guard result.version == "1", result.kind == "speech",
              result.accountId == accountId.uuidString.lowercased(),
              result.operationId == id.uuidString.lowercased() else { throw ManagedSummaryFailure.invalidResponse }
        guard result.state == "succeeded", let clip = result.clip,
              let audio = Data(base64Encoded: clip.audioBase64), !audio.isEmpty else {
            throw ManagedSummaryFailure.refused(code: result.error?.code ?? "no_audio", operationId: result.operationId)
        }
        return SpokenClip(audio: audio, starts: clip.characterStartTimes)
    }

    /// Content IS the identity, as it is for the app's own clip cache: the
    /// same words in the same voice on the same account are one purchase.
    /// Length-framed like the summary's operation id, so two fields cannot be
    /// slid past each other into the same digest.
    static func clipId(text: String, voice: String?, account: UUID) -> UUID {
        var bytes = Data("tb.speech.v1\0".utf8)
        for part in [account.uuidString.lowercased(), voice ?? "", text] {
            let value = Data(part.utf8)
            bytes.append(Data("\(value.count):".utf8)); bytes.append(value)
        }
        var digest = Array(SHA256.hash(data: bytes).prefix(16))
        digest[6] = (digest[6] & 15) | 128
        digest[8] = (digest[8] & 63) | 128
        let hex = digest.map { String(format: "%02x", $0) }
        return UUID(uuidString: [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]]
            .map { $0.joined() }.joined(separator: "-"))!
    }
}

// MARK: - The transcript

struct GatewayTranscriptionToken: Decodable, Sendable {
    let version: String
    let sessionId: String
    let wsUrl: String
    let token: String
    let expiresInSeconds: Int
}

/// A transcription session, opened when the microphone opens and ended when
/// it closes.
///
/// The Gateway charges wall-clock from the moment a session starts, so a
/// session left open is a session being paid for: this ends it as soon as
/// nothing is listening. Each socket the app opens takes its own token, which
/// costs nothing — the minutes are already reserved.
public actor ManagedTranscriptionSession {
    private let accountId: UUID
    private let transport: any GatewayTransport
    private var sessionId: UUID?
    private var renewBy: Date?
    private let now: @Sendable () -> Date

    public init(accountId: UUID, transport: any GatewayTransport,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.accountId = accountId; self.transport = transport; self.now = now
    }

    private func path(_ id: UUID, _ verb: String = "") -> String {
        "/v1/accounts/\(accountId.uuidString.lowercased())/transcription/sessions/\(id.uuidString.lowercased())\(verb)"
    }

    /// A token for one socket, starting or renewing the session as needed.
    public func token(keyterms: [String] = []) async throws -> String {
        if let id = sessionId {
            if let renewBy, now().addingTimeInterval(60) >= renewBy { try await renew(id) }
            do { return try await mint(id) }
            catch ManagedSummaryFailure.refused(let code, _) where code == "session_ended" || code == "not_found" {
                // The session ended underneath us: a fresh one, not a failure.
                sessionId = nil; renewBy = nil
            }
        }
        return try await start(keyterms: keyterms)
    }

    /// Stop paying. Called when the microphone closes; safe to call twice.
    public func end() async {
        guard let id = sessionId else { return }
        sessionId = nil; renewBy = nil
        _ = try? await transport.request(method: "POST", path: path(id, "/end"), body: nil)
    }

    private func start(keyterms: [String]) async throws -> String {
        let id = UUID()
        var body: Data?
        if !keyterms.isEmpty {
            body = try? JSONSerialization.data(withJSONObject: ["keyterms": Array(keyterms.prefix(80))])
        }
        let response = try await transport.request(method: "PUT", path: path(id), body: body)
        guard response.status == 200 else { throw Self.failure(response, id: id) }
        let session = try JSONDecoder().decode(GatewayVoiceSession.self, from: response.body)
        guard session.isValid(account: accountId, id: id, expectSocket: true), let token = session.token else {
            throw ManagedSummaryFailure.invalidResponse
        }
        sessionId = id; renewBy = session.renewByDate
        return token
    }

    private func renew(_ id: UUID) async throws {
        let response = try await transport.request(method: "POST", path: path(id, "/renew"), body: nil)
        guard response.status == 200 else { throw Self.failure(response, id: id) }
        let session = try JSONDecoder().decode(GatewayVoiceSession.self, from: response.body)
        renewBy = session.renewByDate
    }

    private func mint(_ id: UUID) async throws -> String {
        let response = try await transport.request(method: "POST", path: path(id, "/token"), body: nil)
        guard response.status == 200 else { throw Self.failure(response, id: id) }
        let issued = try JSONDecoder().decode(GatewayTranscriptionToken.self, from: response.body)
        guard issued.version == "1", issued.sessionId == id.uuidString.lowercased(),
              !issued.token.isEmpty, URL(string: issued.wsUrl)?.scheme == "wss" else {
            throw ManagedSummaryFailure.invalidResponse
        }
        return issued.token
    }

    private static func failure(_ response: (status: Int, body: Data), id: UUID) -> ManagedSummaryFailure {
        struct Envelope: Decodable { let error: GatewayOperation.ServiceError }
        let code = (try? JSONDecoder().decode(Envelope.self, from: response.body))?.error.code ?? "service_unavailable"
        return .refused(code: code, operationId: id.uuidString.lowercased())
    }
}

// MARK: - What the app installs

/// The two closures the audio providers ask, and the session behind them.
///
/// One object so the transcription session has somewhere to live: it is
/// opened on the first socket of a burst and ended when the microphone
/// closes, because the Gateway charges from the moment it starts.
public final class ManagedAudio: @unchecked Sendable {
    private let session: ManagedCreditSession
    private let log: @Sendable (String) -> Void
    private let live = LiveSession()

    /// How long a session may sit open with nobody speaking before it ends
    /// itself. The Gateway charges wall-clock, so an open session is a paid
    /// one; a burst of utterances shares a session (one round trip, not one
    /// per press), and ninety seconds after the last one it stops costing.
    /// That is 1.8 cents of silence at most per burst, and it means no stop
    /// path anywhere in the app has to remember to close it.
    public static let idleSeconds: TimeInterval = 90

    private final class LiveSession: @unchecked Sendable {
        private let queue = DispatchQueue(label: "managed.transcription")
        private var value: ManagedTranscriptionSession?
        private var idle: DispatchWorkItem?
        func take() -> ManagedTranscriptionSession? {
            queue.sync { idle?.cancel(); idle = nil; let v = value; value = nil; return v }
        }
        func current() -> ManagedTranscriptionSession? { queue.sync { value } }
        func set(_ next: ManagedTranscriptionSession?) { queue.sync { idle?.cancel(); idle = nil; value = next } }
        /// Restarted on every socket: the clock runs from the last one.
        func armIdle(after seconds: TimeInterval, _ close: @escaping @Sendable () -> Void) {
            queue.sync {
                idle?.cancel()
                let work = DispatchWorkItem(block: close)
                idle = work
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
            }
        }
    }

    public init(session: ManagedCreditSession, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.session = session; self.log = log
    }

    /// Whether a refusal means the key path should run: not on credits, or
    /// out of them. Ruled 22 Sep: out of credits falls back to the person's
    /// own ElevenLabs and AssemblyAI keys, the same as summaries fall to their
    /// Anthropic key. #571 had refused instead, and the transcript went to the
    /// same AssemblyAI key anyway through file recovery, seven seconds later.
    static func useOwnKey(_ failure: ManagedSummaryFailure) -> Bool {
        guard case let .refused(code, _) = failure else { return false }
        return code == "not_connected" || code == "rebinding_required" || code == "insufficient_credit"
    }

    /// Out of credits, recorded each time the key path takes over, so the
    /// fallback is visible off the machine even though it is silent on it.
    static func recordFallback(_ kind: String, _ failure: ManagedSummaryFailure) {
        guard case .refused("insufficient_credit", _) = failure else { return }
        Track.record("audio_fallback", ["kind": .token(kind), "reason": "out_of_credits"])
    }

    /// For `ElevenLabsSpeechProvider.render`: a clip bought on the account, or
    /// nil when this Mac is not on credits, or out of them.
    public func clip() -> @Sendable (SanitizedSpokenText, String?, TimeInterval) async throws -> SpokenClip? {
        { [session, log] text, voice, _ in
            let client: ManagedSpeechClient
            do { client = try await session.speech() }
            catch let failure as ManagedSummaryFailure {
                ManagedAudio.recordFallback("voice", failure)
                return nil                             // not on credits, or out: the key path runs
            }
            catch { return nil }
            do { return try await client.speak(text.text, voice: voice) }
            catch let failure as ManagedSummaryFailure {
                if ManagedAudio.useOwnKey(failure) {
                    await session.noteAudioFailure(failure, during: "voice")
                    ManagedAudio.recordFallback("voice", failure)
                    return nil
                }
                log("credits: the voice could not be bought (\(ManagedCreditSession.describe(failure)))")
                await session.noteAudioFailure(failure, during: "voice")
                throw failure                          // a service fault falls to the system voice
            } catch {
                log("credits: the voice could not be bought (\(ManagedCreditSession.describe(error)))")
                await session.noteAudioFailure(error, during: "voice")
                throw error
            }
        }
    }

    /// For `AssemblyAIStreaming.tokenSource`: a token for one socket, or nil
    /// when this Mac is not on credits.
    public func streamingToken(keyterms: @escaping @Sendable () -> [String] = { [] })
        -> @Sendable () async throws -> String? {
        { [session, live, log] in
            let open: ManagedTranscriptionSession
            if let existing = live.current() { open = existing }
            else {
                do { open = try await session.transcription() }
                catch let failure as ManagedSummaryFailure {
                    ManagedAudio.recordFallback("transcript", failure)
                    return nil                         // not on credits, or out: the key path runs
                }
                catch { return nil }
                live.set(open)
            }
            do {
                let token = try await open.token(keyterms: keyterms())
                live.armIdle(after: ManagedAudio.idleSeconds) { [weak live] in
                    guard let session = live?.take() else { return }
                    log("credits: the transcript session went idle; ending it")
                    Task { await session.end() }
                }
                return token
            }
            catch let failure as ManagedSummaryFailure {
                live.set(nil)
                if ManagedAudio.useOwnKey(failure) {
                    await session.noteAudioFailure(failure, during: "transcript")
                    ManagedAudio.recordFallback("transcript", failure)
                    return nil
                }
                log("credits: the transcript could not be bought (\(ManagedCreditSession.describe(failure)))")
                await session.noteAudioFailure(failure, during: "transcript")
                throw failure
            } catch {
                live.set(nil)
                log("credits: the transcript could not be bought (\(ManagedCreditSession.describe(error)))")
                await session.noteAudioFailure(error, during: "transcript")
                throw error
            }
        }
    }

    /// The microphone closed: stop paying for the session.
    public func stopListening() {
        guard let open = live.take() else { return }
        Task { await open.end() }
    }
}
