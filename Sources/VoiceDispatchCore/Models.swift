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
    /// There is deliberately no `status` here.
    ///
    /// An event is a fact about what happened, and facts do not change. Everything
    /// that used to live in a status column is now either derived (waiting =
    /// this is the latest event for its session and it is a Stop) or a fact about
    /// the user rather than the world (heard, dismissed), which lives in
    /// `SessionCursor`. Six code paths used to write that column and none of them
    /// owned it.

    /// Machine-driven, not human-driven: `claude -p` from launchd or cron, with no
    /// controlling terminal. Nothing to open, nothing to answer, and every run gets
    /// a new session id so supersession cannot collapse them either.
    ///
    /// Only an explicit "??" counts. A nil tty is a row written before this was
    /// recorded, and unknown must never be treated as headless: the cost of being
    /// wrong here is silently never announcing a real session.
    public var isHeadless: Bool { tty == "??" }

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
    /// The hook's controlling terminal. "??" means headless. Nil means the row
    /// predates this being recorded, which is unknown rather than headless.
    public var tty: String?
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
        tty: String? = nil,
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
        self.tty = tty
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

/// How far the user has got with one session.
///
/// The only mutable state left in the model, and the only thing that can therefore
/// be wrong. Watermarks rather than booleans, because dismissal is scoped to the
/// item that existed when you dismissed it — Android states it plainly: "If the
/// previous notification is dismissed, a new notification is created instead." A
/// boolean would silence a session for ever; a watermark lets the next turn revive
/// it with nothing written.
public struct SessionCursor: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "session_cursor"

    public var sessionId: String
    /// Event id heard through to the end. Stopping half way does not advance it.
    public var heardThrough: Int64?
    /// Event id explicitly dismissed.
    public var dismissedThrough: Int64?
    /// When you heard it. The reply window measures from your attention, not from
    /// when the agent happened to finish.
    public var heardAtMs: Int64?

    public init(sessionId: String, heardThrough: Int64? = nil,
                dismissedThrough: Int64? = nil, heardAtMs: Int64? = nil) {
        self.sessionId = sessionId
        self.heardThrough = heardThrough
        self.dismissedThrough = dismissedThrough
        self.heardAtMs = heardAtMs
    }

    /// The high-water mark past which this session has nothing to say.
    public var seenThrough: Int64 { max(heardThrough ?? 0, dismissedThrough ?? 0) }
}

/// One persisted brief — a fact about one event, durable across restarts.
///
/// This is the seed row of the product's retention layer: the argument fields
/// (topic, goal, happened, nextStep, question, risk), their spoken projection
/// (recap, proposal), and provenance (callsign, provider, atMs). The in-memory
/// `PreparedSummaries` remains the fast path; this is what it reads through to
/// when the process is new and the memory is gone.
public struct StoredBrief: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "brief"

    /// The events rowid this brief summarizes — the same identity
    /// `PreparedSummaries` keys on (a brief is a brief OF an event).
    public var eventRowid: Int64
    public var sessionId: String
    public var atMs: Int64
    public var topic: String
    public var goal: String?
    public var happened: String
    public var nextStep: String?
    public var question: String?
    public var risk: String?
    /// The ⌃⌃ briefing (v7). Nil on rows written before the column existed.
    public var rationale: String?
    public var recap: String?
    public var proposal: String?
    /// The minted callsign at generation time; nil when not yet minted.
    public var callsign: String?
    /// Which provider generated it ("anthropic", "anthropic+digit-scrubbed", …)
    /// so a restored brief carries its provenance.
    public var provider: String

    /// The brief as the rest of the pipeline consumes it. `branch` is not
    /// persisted — it is deterministic card metadata re-derivable from the
    /// transcript, not part of the argument.
    public var brief: SessionBrief {
        SessionBrief(
            topic: topic, goal: goal, happened: happened, nextStep: nextStep,
            question: question, risk: risk, rationale: rationale, branch: nil,
            recap: recap, proposal: proposal)
    }
}

/// A session with something to say, as returned by the derived query.
///
/// Deliberately not a `QueuedEvent`: it is the answer to a question about a session,
/// not a row from the log. `latestId` is the event it refers to, and is what the
/// cursor is advanced to once you have heard it.
public struct WaitingSession: Codable, FetchableRecord, Sendable {
    public var sessionId: String
    public var latestId: Int64
    public var createdAtMs: Int64
    public var cwd: String?
    public var tty: String?
    public var promptId: String?
    public var transcriptPath: String?
    public var lastAssistantMessage: String?
    public var notificationMatcher: String?
    public var summaryText: String?
    /// The kind of the latest event. `stop` is the only one that waits, but the
    /// summarizer needs to know when it is describing a permission prompt.
    public var hookEvent: HookEventKind
    /// The spoken two-word name minted at the first successful summary and frozen
    /// for the session's lifetime ("promotions copy"). Nil until minted. Exposed
    /// for UI use; the spoken prefix itself is applied by the Coordinator.
    public var callsign: String?
    /// The stored brief's composed topic for this latest event (the 3–6-word
    /// label from the v6 `brief` table), joined in by the grid-feeding queries
    /// (`waitingSessions`, `waitingSessionsIncludingHeard`). Nil when no brief
    /// has been generated for the event yet, or on queries that do not join it.
    /// The grid shows THIS, never a prose prefix of summaryText or the raw
    /// assistant message — composed labels are single-line by construction.
    public var briefTopic: String? = nil

    /// Same derivation the old QueuedEvent used, kept so the summarizer is unchanged.
    public var projectLabel: String {
        guard let cwd, let last = cwd.split(separator: "/").last else { return "session" }
        return String(last)
    }
}
