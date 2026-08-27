import Foundation

/// The loop. Everything else in this package is a part; this is the assembly.
///
/// Deliberately UI-free so it can be driven from `tbase` and from tests exactly as
/// the app drives it — the integration path and the tested path are the same code.
public struct Coordinator: Sendable {
    public let store: QueueStore
    public let summarizer: SummarizerChain
    public let speech: SpeechChain
    public let gate: InterruptGate
    /// The one dispatch transport (single-transport cut, 23 Aug — the
    /// `TerminalAppTransport` fallback this property once chose between with
    /// is deleted, not scheduled for deletion; a `resumeTwin` failure now
    /// refuses cleanly in `dispatch` below instead of rerouting through it).
    public let tmuxTransport: any DispatchTransport

    /// TRANSFERS ownership of a hand-started session dispatch resolved no
    /// tmux pane for — the mechanism `dispatch` reaches for BEFORE falling
    /// to `transport`, added 22 Aug alongside `SessionLauncher.resume`'s own
    /// move off AppleScript (same docs/log/architecture-program.md entry). Named for
    /// what it did until 23 Aug — spin up a "dual-live twin" beside the
    /// hand-started process — a design retired the same day it was found to
    /// leave every reply after the first routed to a tmux pane nobody was
    /// watching, with no way back to the terminal the human actually had
    /// open (sessionId f37aaddd). The default implementation now ends the
    /// hand-started process first and confirms it is gone before resuming
    /// under tmux, so there is exactly one live process per session,
    /// afterward, always tmux-owned. Injected exactly like `agents`/
    /// `transport`, not called as a bare static function: real subprocess
    /// spawns (and, now, real terminations) have no place running
    /// unannounced inside a test's `dispatch()` call, the same reasoning
    /// `recovery`'s own doc comment gives for not defaulting network calls
    /// implicitly. `nil` means the transfer failed (the hand-started process
    /// refused to end, or the tmux resume itself failed) or wasn't
    /// attempted; the caller falls back to `transport` exactly as it did
    /// before this existed.
    /// Carries the HARNESS, because a transfer ends the session before it
    /// resumes it and the wrong harness ends an agent it cannot bring back.
    /// It used to take only an id and a directory, so the resume fell back to
    /// the Settings default launcher — which on 26 Aug was Codex, and killed
    /// a Claude Code session trying to reopen it as `codex --resume`.
    public let resumeTwin: @Sendable (_ sessionId: String, _ directory: String,
                                      _ harness: String) -> TmuxPaneAddress?

    public let enrolment: EnrolmentRegistry
    public let agents: ClaudeAgentsReading
    /// The only source of Codex liveness `waiting()` has — Codex never
    /// appears in `agents` at all, ever, not even after it registers (that
    /// registry is `claude agents --json`, harness-specific by construction).
    /// Found live, 26 Aug, chasing a fresh Codex launch whose greeting card
    /// vanished within five seconds: `SessionSweep` read the freshly-
    /// launched session as permanently "gone" the instant `waiting()` first
    /// polled it, because `live` was built from `agents` alone. A record
    /// written at launch (`AppDelegate+Sessions.swift`, once registration
    /// resolves an id) makes this answerable — see `SessionOwnershipRecord`'s
    /// own doc comment: "the fact Claude Code's own `agents --json` gives
    /// for free and no other harness does."
    public let ownership: any SessionOwnershipStore
    /// Extracted from `Coordinator` into its own injectable type (23 Aug,
    /// Coordinator-split rider) — see `SessionSweep`'s own doc comment for
    /// why. `.shared` by default, matching the old static state's behavior:
    /// one sweep memory per process, however many `Coordinator` values get
    /// constructed around the same store.
    public let sweep: SessionSweep
    /// Injected rather than defaulted at the call site, so tests can run the whole
    /// loop without touching the network. Left implicit, the coordinator's own tests
    /// were quietly uploading silence to a paid transcription API.
    public let recovery: RecoveryChain
    /// Files staged by drag-and-drop to ride the next voice reply (the drop
    /// tray). A reference alongside a value-type Coordinator, like
    /// PreparedSummaries — the panel reads chips synchronously in render().
    public let attachments: AttachmentStore

    /// How long after speaking a session stays the reply target. Long enough to
    /// think, short enough that a reply can't land somewhere you've forgotten about.
    public let replyWindow: TimeInterval

    /// How long a dispatch waits for a session that is not in
    /// `claude agents --json` yet. A brand-new agent can register, bind, and
    /// then briefly drop out again before it has taken any input; without this
    /// the reply was refused and the user was told to try again by hand.
    /// Zero in tests that assert the refusal itself.
    public let readinessGrace: TimeInterval

    public init(
        store: QueueStore,
        summarizer: SummarizerChain = SummarizerChain(),
        speech: SpeechChain = SpeechChain(),
        gate: InterruptGate = InterruptGate(),
        tmuxTransport: any DispatchTransport = TmuxTransport(),
        enrolment: EnrolmentRegistry = EnrolmentRegistry(),
        agents: ClaudeAgentsReading = ClaudeAgentsCLI(),
        ownership: any SessionOwnershipStore = FileSessionOwnershipStore.shared,
        sweep: SessionSweep = .shared,
        recovery: RecoveryChain = RecoveryChain(),
        attachments: AttachmentStore = AttachmentStore(),
        replyWindow: TimeInterval = 15 * 60,
        readinessGrace: TimeInterval = 12,
        resumeTwin: @escaping @Sendable (_ sessionId: String, _ directory: String,
                                         _ harness: String) -> TmuxPaneAddress?
            = { sessionId, directory, harness in
                // Ownership TRANSFER, not a parallel twin (reversed 23 Aug,
                // on the operator's direct correction) — the shared
                // mechanism, `SessionLauncher.OwnershipTransfer.toTmux`, also
                // used by GO TO AGENT for the same reason: no parallel
                // human+tmux session, ever, on ANY interaction with a
                // hand-started session, not just its first dispatch. See
                // that function's own doc comment for the "dual-live is
                // safe" premise this reverses and why.
                SessionLauncher.OwnershipTransfer.toTmux(
                    sessionId: sessionId,
                    launch: HarnessLaunch(harness: harness),
                    directory: directory)?.pane
            }
    ) {
        self.store = store
        self.prepared = PreparedSummaries()
        self.summarizer = summarizer
        self.speech = speech
        self.gate = gate
        self.tmuxTransport = tmuxTransport
        self.enrolment = enrolment
        self.agents = agents
        self.ownership = ownership
        self.sweep = sweep
        self.recovery = recovery
        self.attachments = attachments
        self.replyWindow = replyWindow
        self.readinessGrace = readinessGrace
        self.resumeTwin = resumeTwin
    }

    // MARK: - Intake

    /// Set by the app. Routing decisions are logged because the one failure that
    /// cannot be undone — words typed into a session you were not talking to —
    /// otherwise leaves no evidence at all.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    @discardableResult
    public func intake() throws -> SpoolDrainer.DrainResult {
        try SpoolDrainer(store: store).drain()
    }

    /// Summaries computed in memory, ahead of being asked for.
    ///
    /// Summarizing on demand meant every single use began with a wait for a model
    /// call — the whole point is to hear a session while your attention is
    /// elsewhere, and a four-second pause after you press is the tax that makes
    /// you stop pressing. Only the newest turn per session is prepared, which is
    /// also the only one that can be announced, so nothing is paid for twice.
    /// An actor because `Coordinator` is a value type and preparation happens on a
    /// background task while announcement may read it from another.
    actor PreparedSummaries {
        /// Keyed by session, VALID only for one specific latest event.
        ///
        /// Keying by session alone played a stale summary aloud: one prepared for
        /// the Cloudflare-token turn survived while the session moved two turns on,
        /// and the announcement spoke about work the user had already answered. A
        /// summary is a summary OF an event, so the event id is part of its
        /// identity — a mismatch discards rather than serves.
        private var bySession: [String: (latestId: Int64, summary: Summary)] = [:]
        func has(_ id: String, latest: Int64) -> Bool { bySession[id]?.latestId == latest }
        func put(_ summary: Summary, for id: String, latest: Int64) {
            bySession[id] = (latest, summary)
        }
        /// Read WITHOUT consuming — for warming the audio of something already
        /// prepared. `take` is the announcement path and must stay destructive;
        /// this one must not be, or a prefetch would eat the summary it is
        /// trying to make faster.
        func peek(_ id: String, latest: Int64) -> Summary? {
            guard let entry = bySession[id], entry.latestId == latest else { return nil }
            return entry.summary
        }
        /// Removing on read keeps a summary from being spoken twice.
        func take(_ id: String, latest: Int64) -> Summary? {
            guard let entry = bySession.removeValue(forKey: id),
                  entry.latestId == latest else { return nil }
            return entry.summary
        }
    }

    let prepared: PreparedSummaries
}
