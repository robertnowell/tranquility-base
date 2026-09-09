import Foundation

/// Machine observations, never a claim that a person spoke or stayed silent.
public enum TranscriptionDisposition: String, Codable, Sendable {
    case completed
    case noSpeechDetected = "no_speech_detected"
    case providerError = "provider_error"
    case unresolved
    case cancelled
}

public struct TranscriptionAttempt: Equatable, Sendable {
    public var provider: String
    public var configured: Bool
    public var outcome: String
    public var errorCode: String?
    public var durationMs: Int
    public var ordinal: Int

    func record() {
        var props: [String: TrackValue] = [
            "provider": Track.token(from: provider), "phase": "recovery",
            "configured": .bool(configured), "outcome": .token(outcome),
            "duration_ms": .int(durationMs), "attempt": .int(ordinal),
        ]
        if let errorCode { props["error_code"] = .token(errorCode) }
        Track.record("transcription_attempt", props)
    }

    public static func disposition(of attempts: [Self]) -> TranscriptionDisposition {
        if attempts.contains(where: { $0.outcome == "completed" }) { return .completed }
        let executed = attempts.filter { $0.configured && $0.outcome != "cancelled" }
        if !executed.isEmpty && executed.allSatisfy({ $0.errorCode == "no_speech_detected" }) {
            return .noSpeechDetected
        }
        if attempts.contains(where: { $0.outcome == "cancelled" }) { return .cancelled }
        if attempts.contains(where: { $0.errorCode != nil && $0.errorCode != "no_speech_detected" }) {
            return .providerError
        }
        return .unresolved
    }
}

extension TranscriptionFailure {
    /// Free-form errors can include URLs or partial transcripts. Export the
    /// bounded category instead; the detailed error remains in the local store.
    public var diagnosticCode: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .authenticationFailed: return "authentication_failed"
        case .connectionDropped: return "connection_dropped"
        case .sessionExpired: return "session_expired"
        case .audioRateExceeded: return "audio_rate_exceeded"
        case .noSpeechDetected: return "no_speech_detected"
        case .truncatedNoFinality: return "missing_finality"
        case .fileUnreadable: return "file_unreadable"
        case .offline: return "offline"
        case .providerUnavailable: return "provider_unavailable"
        case .providerHTTP(let status, let stage): return "\(stage)_http_\(status)"
        }
    }
}
