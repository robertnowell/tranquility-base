import Foundation
import GRDB

// MARK: - Events (announcements)
//
// An event is "a turn ended in some session, and the user may want to hear about it."
// Events are NOT durability-critical: if one is lost, the information still exists in
// Claude Code's own transcript. That asymmetry is deliberate and keeps the durable
// surface small — only `Utterance` (the user's recorded voice) must never be lost.

public enum HookEventKind: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case stop = "Stop"
    case notification = "Notification"
    case subagentStop = "SubagentStop"
    /// Not announced. Carries the fact that the user typed into that session,
    /// which retires anything of that session's still waiting to be read out.
    case userPromptSubmit = "UserPromptSubmit"
}

public enum EventStatus: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    /// Written by the hook, not yet processed.
    case new
    /// A spoken summary exists.
    case summarized
    /// The gate vetoed announcing right now; still waiting.
    case held
    /// Spoken to the user.
    case announced
    /// User replied — an Utterance row points at this event.
    case answered
    /// User dismissed it, or it aged out of relevance.
    case dismissed
    /// A newer turn from the same session replaced it, or the user typed into
    /// that session themselves. Never announced, never deleted — the record of
    /// what was skipped is worth keeping.
    case superseded
    /// Summarization failed; a deterministic fallback line is used instead.
    case summaryFailed = "summary_failed"

    /// Statuses that are still candidates to be spoken.
    public static let pendingAnnouncement: [EventStatus] = [.new, .summarized, .held]

    /// Statuses that no longer need any work.
    public static let terminal: Set<EventStatus> = [.answered, .dismissed]
}

public struct QueuedEvent: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "events"

    public var id: String
    public var createdAtMs: Int64
    public var hookEvent: HookEventKind
    public var sessionId: String
    /// Dedupe key. A turn that fans out to subagents fires one `Stop` plus N
    /// `SubagentStop`, all sharing a `prompt_id`. We announce the `Stop` only.
    public var promptId: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var lastAssistantMessage: String?
    /// For `Notification` events: `permission_prompt`, `idle_prompt`, etc.
    public var notificationMatcher: String?
    public var status: EventStatus
    public var summaryText: String?
    public var summaryError: String?
    public var announcedAtMs: Int64?

    public init(
        id: String = UUID().uuidString,
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        hookEvent: HookEventKind,
        sessionId: String,
        promptId: String? = nil,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        lastAssistantMessage: String? = nil,
        notificationMatcher: String? = nil,
        status: EventStatus = .new,
        summaryText: String? = nil,
        summaryError: String? = nil,
        announcedAtMs: Int64? = nil
    ) {
        self.id = id
        self.createdAtMs = createdAtMs
        self.hookEvent = hookEvent
        self.sessionId = sessionId
        self.promptId = promptId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.lastAssistantMessage = lastAssistantMessage
        self.notificationMatcher = notificationMatcher
        self.status = status
        self.summaryText = summaryText
        self.summaryError = summaryError
        self.announcedAtMs = announcedAtMs
    }

    /// Short human label for the CLI and menu bar — last path component of cwd.
    public var projectLabel: String {
        guard let cwd, !cwd.isEmpty else { return sessionId.prefix(8).description }
        return (cwd as NSString).lastPathComponent
    }
}

// MARK: - Utterances (the durable half)
//
// An utterance is one recorded voice reply. Its audio file is written to disk at
// key-up BEFORE any network call, and the row is the crash log: no audio is ever
// deleted while its row still needs it.

public enum UtteranceStatus: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    /// Audio is on disk. This is the durability floor — from here on, the audio
    /// is never deleted until the row reaches `confirmed` or `discarded`.
    case recorded
    case transcribing
    case transcribed
    /// Transcript exists and a dispatch target is resolved.
    case ready
    /// Pre-flight passed; we are about to inject.
    case dispatching
    /// Keystrokes sent, read-back not yet confirmed.
    case dispatchedUnconfirmed = "dispatched_unconfirmed"
    case confirmed
    /// Transcription exhausted every provider. Audio retained for manual retry.
    case transcriptionFailed = "transcription_failed"
    /// Dispatch failed for a knowable reason (target gone, never became ready).
    case dispatchFailed = "dispatch_failed"
    /// We crashed between sending keystrokes and confirming. We do NOT know whether
    /// the text landed, and a duplicate injection is worse than a dropped one — so
    /// this state is never auto-resolved. A human decides.
    case ambiguousAfterCrash = "ambiguous_after_crash"
    case discarded

    /// The ONLY statuses whose audio the retention sweep may delete.
    public static let reapable: Set<UtteranceStatus> = [.confirmed, .discarded]

    /// Statuses the boot sweep must pick back up.
    public static let inFlight: Set<UtteranceStatus> = [
        .recorded, .transcribing, .transcribed, .ready, .dispatching, .dispatchedUnconfirmed,
    ]

    public var isTerminal: Bool {
        switch self {
        case .confirmed, .discarded, .transcriptionFailed, .dispatchFailed, .ambiguousAfterCrash:
            return true
        default:
            return false
        }
    }
}

/// How much we trust that the transcript is the complete utterance.
/// Never a bare string — Clicky's silent-truncation bug came from treating a
/// timed-out partial as if it were a real final.
public enum TranscriptFinality: String, Codable, DatabaseValueConvertible, Sendable {
    /// The provider explicitly signalled end of turn. Trustworthy.
    case explicitEndOfTurn = "explicit_end_of_turn"
    /// A fallback timer fired before any end-of-turn signal. May be truncated.
    case fallbackTimeout = "fallback_timeout"
    /// Produced by a file-based recovery pass over the whole saved audio.
    case recoveryForcedFinal = "recovery_forced_final"

    public var isTrustworthy: Bool {
        self != .fallbackTimeout
    }
}

/// Which terminal implementation owns the target. Stored so a post-crash recovery
/// resolves through the same transport it originally used.
public enum TransportKind: String, Codable, DatabaseValueConvertible, Sendable {
    case terminalApp = "terminal_app"
    case iTerm2 = "iterm2"
    case wezterm
    case kitty
    case tmux
}

public struct Utterance: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "utterances"

    public var id: String
    public var eventId: String?
    public var createdAtMs: Int64
    public var status: UtteranceStatus

    // Audio — the durable artifact. `id` is also the filename stem.
    public var audioPath: String?
    public var audioBytes: Int64?
    public var audioSha256: String?
    public var audioDurationMs: Int64?

    // Transcript
    public var transcriptText: String?
    public var transcriptProvider: String?
    public var transcriptFinality: TranscriptFinality?

    // Dispatch target, captured at record time and re-resolved at dispatch time.
    public var targetKind: TransportKind?
    public var targetSessionId: String?
    public var targetPid: Int?
    public var targetTty: String?

    public var dispatchAttempts: Int
    public var lastDispatchAtMs: Int64?
    public var lastError: String?
    public var confirmedAtMs: Int64?
    public var discardedReason: String?

    public init(
        id: String = UUID().uuidString,
        eventId: String? = nil,
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        status: UtteranceStatus = .recorded,
        audioPath: String? = nil,
        audioBytes: Int64? = nil,
        audioSha256: String? = nil,
        audioDurationMs: Int64? = nil,
        transcriptText: String? = nil,
        transcriptProvider: String? = nil,
        transcriptFinality: TranscriptFinality? = nil,
        targetKind: TransportKind? = nil,
        targetSessionId: String? = nil,
        targetPid: Int? = nil,
        targetTty: String? = nil,
        dispatchAttempts: Int = 0,
        lastDispatchAtMs: Int64? = nil,
        lastError: String? = nil,
        confirmedAtMs: Int64? = nil,
        discardedReason: String? = nil
    ) {
        self.id = id
        self.eventId = eventId
        self.createdAtMs = createdAtMs
        self.status = status
        self.audioPath = audioPath
        self.audioBytes = audioBytes
        self.audioSha256 = audioSha256
        self.audioDurationMs = audioDurationMs
        self.transcriptText = transcriptText
        self.transcriptProvider = transcriptProvider
        self.transcriptFinality = transcriptFinality
        self.targetKind = targetKind
        self.targetSessionId = targetSessionId
        self.targetPid = targetPid
        self.targetTty = targetTty
        self.dispatchAttempts = dispatchAttempts
        self.lastDispatchAtMs = lastDispatchAtMs
        self.lastError = lastError
        self.confirmedAtMs = confirmedAtMs
        self.discardedReason = discardedReason
    }
}
