import Foundation

/// File-based AssemblyAI recovery — the vendor-diversity rung.
///
/// Born 12 Aug, from the incident it would have prevented: the 27-minute
/// dictation's 52MB WAV was recovered BY HAND through exactly this API in
/// ~30 seconds, whole, while both in-repo rungs failed on it — Whisper's
/// edge kills big uploads mid-transfer, and the Apple floor had stopped at
/// 60 seconds under in-app churn. A chain whose rungs share a vendor shares
/// their outages; this one fails independently of both neighbours.
///
/// The streaming provider cannot transcribe a file (the two-protocol split in
/// Transcription.swift exists precisely so recovery can run on a different
/// vendor than the live attempt) — this conformer shares nothing with the
/// socket path but the key. No lexicon reaches this rung: the file API's
/// vocabulary params are unverified against the models used here, and the
/// primary rung already carries the Whisper prompt.
public struct AssemblyAIFileRecovery: RecoveryTranscriptionProvider {
    public let name = "assemblyai-file"

    /// Same disclosure stance as the other transcription traces: one line per
    /// stage, wired to Permissions.log in the app and prints in the CLI.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    /// Test seam, as everywhere else: tests neither read nor mutate the real
    /// secrets file.
    var keySource: @Sendable () -> String? = { Secrets.read(.assemblyAIAPIKey) }

    /// Poll cadence and ceiling. The incident's 27-minute file completed in
    /// well under two minutes; the ceiling is generous because this rung runs
    /// off the critical path — nobody is watching a spinner on it.
    static let pollInterval: TimeInterval = 3
    static let pollCeiling: TimeInterval = 600

    public init() {}

    init(keyOverride: String?) {
        self.keySource = { keyOverride }
    }

    public var isConfigured: Bool { keySource() != nil }

    enum TranscriptState: Equatable {
        case processing
        case completed(String)
        case failed(String)
    }

    /// One poll response, reduced. Pure so the terminal-state rules are
    /// testable without a network: "queued" and "processing" are the same
    /// non-answer, "completed" carries its text, "error" carries its reason.
    static func state(of json: [String: Any]) -> TranscriptState {
        switch json["status"] as? String {
        case "completed":
            let text = ((json["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .completed(text)
        case "error":
            return .failed((json["error"] as? String) ?? "unspecified")
        default:
            return .processing
        }
    }

    public func transcribe(fileAt url: URL) async throws -> TranscriptionResult {
        guard let key = keySource() else { throw TranscriptionFailure.notConfigured }
        guard let audio = try? Data(contentsOf: url) else { throw TranscriptionFailure.fileUnreadable }

        // 1. Upload — the whole file, no slicing. Transport errors map into
        //    the failure taxonomy so the chain's backoff applies, same lesson
        //    as the Whisper rung's TLS abort.
        var upload = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/upload")!)
        upload.httpMethod = "POST"
        upload.timeoutInterval = 300
        upload.setValue(key, forHTTPHeaderField: "Authorization")  // raw key — no "Bearer"
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let uploaded: String
        do {
            let (data, response) = try await URLSession.shared.upload(for: upload, from: audio)
            guard let http = response as? HTTPURLResponse else {
                throw TranscriptionFailure.providerUnavailable("upload: no response")
            }
            if http.statusCode == 401 { throw TranscriptionFailure.authenticationFailed }
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uploadURL = json["upload_url"] as? String
            else {
                throw TranscriptionFailure.providerUnavailable("upload: http \(http.statusCode)")
            }
            uploaded = uploadURL
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch {
            throw TranscriptionFailure.fromTransport(error)
        }
        Self.trace?("uploaded \(audio.count) bytes")

        // 2. Create the transcript. `speech_models` plural — the singular
        //    `speech_model` is deprecated and the API errors on it (verified
        //    12 Aug, the hard way).
        var create = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!)
        create.httpMethod = "POST"
        create.timeoutInterval = 60
        create.setValue(key, forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try? JSONSerialization.data(withJSONObject: [
            "audio_url": uploaded,
            "speech_models": ["universal-3-5-pro", "universal-2"],
        ])
        let transcriptId: String
        do {
            let (data, response) = try await URLSession.shared.data(for: create)
            guard let http = response as? HTTPURLResponse else {
                throw TranscriptionFailure.providerUnavailable("create: no response")
            }
            if http.statusCode == 401 { throw TranscriptionFailure.authenticationFailed }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String
            else {
                let reason = ((try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any])?["error"] as? String) ?? "http \(http.statusCode)"
                throw TranscriptionFailure.providerUnavailable("create: \(reason)")
            }
            transcriptId = id
        } catch let failure as TranscriptionFailure {
            throw failure
        } catch {
            throw TranscriptionFailure.fromTransport(error)
        }

        // 3. Poll to a terminal state.
        let deadline = Date().addingTimeInterval(Self.pollCeiling)
        var poll = URLRequest(
            url: URL(string: "https://api.assemblyai.com/v2/transcript/\(transcriptId)")!)
        poll.setValue(key, forHTTPHeaderField: "Authorization")
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            guard let (data, _) = try? await URLSession.shared.data(for: poll),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }  // one flaky poll is not a failed transcript
            switch Self.state(of: json) {
            case .processing:
                continue
            case .failed(let reason):
                throw TranscriptionFailure.providerUnavailable("transcript error: \(reason)")
            case .completed(let text):
                Self.trace?("completed: \(text.count) chars")
                guard !text.isEmpty else { throw TranscriptionFailure.noSpeechDetected }
                return TranscriptionResult(
                    text: text, finality: .recoveryForcedFinal, provider: name)
            }
        }
        throw TranscriptionFailure.providerUnavailable(
            "transcript \(transcriptId) not terminal after \(Int(Self.pollCeiling))s")
    }
}
