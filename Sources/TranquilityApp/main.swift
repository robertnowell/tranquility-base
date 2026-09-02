import AppKit
import CryptoKit
import Foundation
import TranquilityCore

/// Menu-bar-only app (`LSUIElement`). No dock icon, no main window.
///
/// This is the shell the loop lives in: it owns the hotkey tap, the microphone, and
/// the permission state that neither can work without. Everything it coordinates —
/// the queue, the summarizer, dispatch — is in TranquilityCore and is exercised by
/// `tbase` without any of this.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Every voice with a checkmark, across BOTH rosters.
    ///
    /// The settings pane draws its ticks from a single array, so it needs the
    /// union — while the STORAGE stays two files, which is what stops a system id
    /// being dialled up as a cloud voice.
    static func checkedVoices() -> [String] {
        VoiceRoster.load() + VoiceRoster.loadSystem()
    }

    var statusItem: NSStatusItem!
    var hotkey: HotkeyMonitor!
    let recorder = Recorder()
    var store: QueueStore?
    var coordinator: Coordinator?
    var permissionTimer: Timer?
    var intakeTimer: Timer?
    let onboarding = OnboardingWindow()
    let utterancePlayer = UtterancePlayer()
    let hud = StatusHUD()

    var lastStatusLine = "starting…"
    var isBusy = false

    /// The menu-bar badge's waiting count, sampled OFF the main thread.
    ///
    /// `Coordinator.waitingCount()` reaches `ClaudeAgentsCLI.sessions()`, which
    /// runs `claude agents --json` as a child process with an 8-second deadline.
    /// `updateTitle()` called it inline, `refresh()` calls `updateTitle()`, and
    /// the permission timer calls `refresh()` every 1.5 seconds — so the main
    /// thread went into a subprocess wait on a repeating timer. The 6-second
    /// result cache hid it most ticks and hid it completely on a fast machine
    /// with a warm CLI; on the first external user's Mac the crash report caught
    /// thread 0 mid-wait, three frames deep in `Subprocess.run` (incident
    /// 51344D00, 25 Aug).
    ///
    /// That is rule 9 exactly — "anything whose cost a human would feel as a
    /// frozen frame runs detached and hops back for the UI half" — and the
    /// deadline that was added when this last bit (audit R5) bounded how long
    /// the freeze lasts without moving which thread freezes.
    ///
    /// So the badge reads a number and never a process. `refreshWaitingSnapshot`
    /// samples off-main and repaints only on change. The count starts at 0 and
    /// is correct within one probe of launch, which is the honest trade: a badge
    /// that is briefly zero beats a menu bar that is briefly frozen.
    ///
    /// It also warms the shared 6-second cache every tick, so the keypress paths
    /// that still call `waiting()` inline (they need the rows, not a count, and
    /// freshness at the moment of a press is load-bearing) almost always hit a
    /// warm cache instead of a spawn.
    var waitingCountSnapshot = 0

    /// One probe at a time. Without this a slow CLI stacks a new child process
    /// every 1.5 seconds behind the last one that has not come back.
    var waitingProbeInFlight = false

    /// Probes started and probes finished, monotonic.
    ///
    /// `waitingProbeInFlight` cannot answer "did MY probe run", because this
    /// app probes on a 1.5-second timer and the flag belongs to whichever
    /// probe is current. `refreshIsCheapDrill` asserted on it anyway and
    /// failed on the first deploy that ran it: its own probe had long since
    /// completed (the badge had the answer) while the flag read true for the
    /// timer's next one. Counters are the fix, because a count that went up
    /// cannot be somebody else's.
    var waitingProbesStarted = 0
    var waitingProbesCompleted = 0

    /// Tap versus hold on the same chord. A tap plays the next waiting update; a
    /// hold records a reply to whatever last spoke. One gesture, two verbs — which
    /// beats two chords to remember, and the boundary is unambiguous in practice
    /// because nobody holds a key for a third of a second by accident.
    static let tapThreshold: TimeInterval = 0.35

    /// How long the microphone must have been open before a silence-gated
    /// recording is worth saying anything about (ruled 08 Aug). Not a send
    /// threshold — the gate above it is unchanged, and a real 1.2-second "yes,
    /// do it" still goes. This is purely how long you have to have HELD the key
    /// before "no words" is news rather than noise about a slip of the thumb.
    ///
    /// Two seconds because a deliberate utterance is essentially never shorter,
    /// and every sub-second capture the log has ever gated was an accident.
    static let notionalUtterance: TimeInterval = 2.0

    /// Past this, a recording that carried NO signal at all stops being a quiet
    /// room and starts being a broken input. Five seconds of holding a key is a
    /// deliberate, sustained act; a microphone that produced nothing across it
    /// is not waiting for you to speak up, it is not working.
    static let deviceFaultHold: TimeInterval = 5.0
    var pressStartedAt: Date?
    var listeningIndicator: DispatchWorkItem?
    /// Instant-arm (docs/instant-arm.md): when the arm window opened and the
    /// recorder started capturing optimistically. nil = no optimistic capture
    /// live. Consumed at resolution — cleared by the upgrade (replyBegan) and
    /// by the abort (armAborted), never left set across gestures.
    var armedAt: Date?
    /// Whether the arming FACE painted (the legality table refuses it over
    /// capture states; audio can arm without pixels).
    var armedVisually = false
    /// Guards against overlapping announcements. `speech.isSpeaking` is false while
    /// the audio is still being fetched, so two quick taps used to start two
    /// announcements that then talked over each other.
    var isAnnouncing = false
    /// Set when a reply interrupts playback, so the announce task does not undo the
    /// markHeard that made the reply possible.
    var repliedToEventId: String?
    /// The one announcement allowed to exist. See `announceNext`.
    var announceTask: Task<Void, Never>?
    /// Where the ⌃⌥ walk over an all-opened stack has got to. Nil means start
    /// at the top. In memory only, and reset by any fresh or named
    /// announcement — a walk is a gesture in progress, not durable state.
    var lastReplayed: String?
    /// The session this recording is addressed to, captured at the moment the
    /// microphone opens and consumed by the send.
    ///
    /// The send used to re-derive its target when the audio arrived — seconds after
    /// you started talking, through fallback chains that could resolve differently
    /// by then. The HTML button replied to the wrong session exactly that way. What
    /// the panel names while you speak and what the send addresses must be the SAME
    /// stored fact, not two derivations that usually agree.
    var recordingDestination: ReplyDestination?

    /// The launch this capture is answering, when the agent has no id yet.
    ///
    /// Was three fields until 24 Aug — `recordingTarget`, `recordingLaunch` and
    /// `dictationMode` — which is eight representable states for a fact with
    /// three. The misroute that ended that arrangement was the app sitting in
    /// one of the five that were not legal: no launch claim, no adoption yet,
    /// and an `if/else` with nothing to match, which fell through and addressed
    /// six and a half minutes of speech to the previous agent. See
    /// `ReplyDestination`, and `ReplyRouting.destination` for who decides it.

    /// The launch that is still coming up, if any.
    var pendingLaunch: PendingLaunch?
    /// Sessions this app is mid-delivery to, so the grid can say so. See
    /// `DeliveryInFlight`: the target's own transcript cannot know about a
    /// reply until it lands, so for the whole transcribe → confirm → dispatch
    /// window the row read quiet — the one stretch the user KNOWS is busy,
    /// because they started it. Consumed by `lamp(for:sessionId:)`.
    var delivering = DeliveryInFlight()
    /// A session that legitimately WAS live a moment ago and is briefly
    /// absent from `claude agents --json`'s own listing — not dead, just
    /// caught between two polls of a registry that has its own transient
    /// gaps. Found live, 23 Aug: dispatching to a session that had been
    /// running for hours made it vanish from `sessionRowsNow()`'s probe for
    /// 3-5 seconds while it started consuming the new input, which demoted
    /// its row all the way to "closed (revivable)" and knocked it out of
    /// the grid's visible window — worse than stale, it looked like the
    /// session had just died.
    ///
    /// A short grace window, not a fix to the registry itself (this app
    /// does not own `claude agents --json`): consulted and maintained
    /// entirely inside `sessionRowsNow()`.
    static let liveGrace: TimeInterval = 8
    var lastSeenLive: [String: (session: LiveSession, at: Date)] = [:]
    /// How many Codex names the last repaint had. Logged only when it moves,
    /// because the number going to zero is the one thing that renames every
    /// Codex row to its directory at once, and until 31 Aug there was nothing
    /// in the log to see it by — three separate investigations reasoned about
    /// bands while the input was never checked.
    var lastCodexNameCount = -1
    /// Which harness each session runs, rebuilt every repaint from the live
    /// map and the rows. One map, so the card and the grid cannot disagree.
    var harnessById: [String: String] = [:]
    /// Hands-free listening: started by a double-tap of ⌥, ended by a single tap.
    /// Distinct from the push-to-talk flag because releasing a key you are not
    /// holding must not end anything.
    var handsFreeListening = false
    var lastOptionTapAt: Date?
    /// When hands-free listening last opened, so the twin of a ⌥⌥ cannot close
    /// what the first tap opened. See OptionTapDecision's THE TWIN note.
    var listeningStartedAt: Date?
    /// The conversation you are in: set when an announcement starts and kept
    /// through any number of replies, until you explicitly move on (⌃⌥ or dismiss).
    ///
    /// The cursor-derived target could not carry this. Mid-playback the cursor has
    /// not advanced yet, so a reply resolved to the PREVIOUS session — observed:
    /// listening to one session, replying to an older one. And after a send, the
    /// session's own user_prompt_submit lands seconds later, heardThrough stops
    /// matching latest, and the derived target vanishes — which is why a second
    /// message to the same session was so hard. A conversation is an app-level
    /// fact about your attention, not a log-level fact.
    var activeConversation: (sessionId: String, label: String, cwd: String?)?
    /// The most recent announcement, kept whole so ⌃⌃ can speak its depth-1
    /// (goal, risk, question) from the already-computed brief — no model call,
    /// and the session itself is never woken.
    var lastAnnouncement: Coordinator.Announcement?
    /// Which utterance we have already queued a follow-on render for, so the
    /// eight-per-second highlight tick cannot spawn eight prefetches.
    var warmedAfter: String?

    /// Render the rung the user is most likely to ask for next, WHILE the
    /// current one is playing.
    ///
    /// Deliberately not at turn arrival. Measured over 123 announcements: 72%
    /// get at least one ⌃⌃, and of those essentially every walk opens on
    /// FINDINGS — but a rung is ~1.4x the announcement's length, so rendering
    /// the whole ladder up front is ~4x the credits for a pull a quarter of
    /// announcements never make. Gating on "the main clip is actually playing"
    /// buys the common case at close to its true hit rate, and the fetch hides
    /// entirely under a twenty-second read.
    ///
    /// The MESSAGE rung is `announcement.spoken` verbatim, so its cache key is
    /// the announcement's and it warms for free.
    func warmNextRung(after index: Int, token: String) {
        guard warmedAfter != token else { return }
        warmedAfter = token
        guard let announcement = lastAnnouncement, let coordinator else { return }
        let rungs = SpokenComposition.ladderRungs(for: announcement)
        guard !rungs.isEmpty else { return }
        let next = rungs[index % rungs.count]
        let voice = coordinator.voiceId(for: announcement.event.sessionId)
        let speech = coordinator.speech
        Permissions.log("prewarm: queueing \(next.kind.rawValue) (\(next.spoken.text.count) chars)")
        // Utility priority and detached: this must never compete with the audio
        // currently playing or with the highlight driving off it.
        Task.detached(priority: .utility) {
            await speech.prewarm(next.spoken, voice: voice)
        }
    }

    /// The ⌃⌃ ladder walk: which announcement it belongs to, and the next rung.
    /// A new announcement resets the walk; wrapping past the end is "say again".
    var ladderKey: String?
    var ladderIndex = 0
    /// Ruling 14, REVERSED for spoken cards (Robert, 12 Aug): a finished
    /// announcement or ⌃⌃ pull dwells until a gesture moves it — the reader,
    /// not a clock, decides when the card has been read. The original ruling
    /// (8985bbe, 05 Aug: "no gesture within ~4s returns the panel to the
    /// grid") was made three days after the isPaused hang shipped, so on the
    /// ElevenLabs path it was never once experienced until the hang was fixed
    /// on 11 Aug — and the first real exposure reversed it. The dictation
    /// receipt (ui-pass-7, ruling 5) is a different ruling and still
    /// auto-returns: it is a passive confirmation with nothing left to act on.
    var returnToGridWork: DispatchWorkItem?
    /// Who a dropped file would be staged for, and whose chips the panel is
    /// therefore showing. One value answers both, so what you can see is
    /// always exactly what would ride.
    ///
    /// Cached, and deliberately NOT `resolveReplyContext()`: that probe
    /// shells out for a pid, and this is read on every repaint. Refreshed on
    /// the tick and at every moment that changes the addressee.
    var dropTarget: (sessionId: String, label: String)?
    static let returnToGridDelay: TimeInterval = 4
    /// Incremented every time a reply gesture starts.
    ///
    /// Cancelling the countdown only covers the four seconds it is on screen.
    /// Speaking again during transcription — the gap between letting go and the
    /// window appearing — left the earlier reply in flight with nothing watching
    /// it, so it surfaced and sent anyway. A counter covers both windows and any
    /// future one, because it asks "is this still the reply the user wants" rather
    /// than "is a particular UI state showing".
    var replyGeneration = 0
    /// The transcription attempt the panel is showing, held so the card's
    /// Retry can actually reach it. Everything a fresh attempt needs to run
    /// the SAME capture again: the audio (still in memory), the addressing
    /// facts sendReply consumes (they are nulled as the attempt runs, so a
    /// retry must restore them), and the attempt's pre-minted utterance row
    /// so the superseded twin can be retired from the recent-audio pane.
    /// Cleared when the attempt resolves while still current.
    struct InFlightTranscription {
        let capture: Recorder.Capture
        let utteranceId: String
        let destination: ReplyDestination?
        var task: Task<Void, Never>?
    }
    var inFlightTranscription: InFlightTranscription?
    /// What the idle grid is currently displaying — row DATA, not counts — so it
    /// is redrawn on content change rather than on every poll. Counts alone
    /// missed real changes: a newer turn replacing an older one leaves the count
    /// identical, and a summary arriving changes a row's topic with no count
    /// change at all.
    var lastShownRows: [SessionRow]?
    /// Which sessions were already waiting on the previous tick.
    ///
    /// `turnArrived` is honest about a TURN arriving — it keys off rows being
    /// inserted, deliberately, because "a newer turn superseding an older one
    /// leaves the count identical, and that is the commonest case of all." That is
    /// the right trigger for repainting. It is the WRONG trigger for a sound.
    ///
    /// Reported 18 Aug: the return cue fired seconds after a send with nothing new
    /// in the grid. It was not a false positive in the strict sense — a turn had
    /// genuinely landed — but it landed on a session that was ALREADY green, so
    /// nothing the user could act on had changed. A cue that fires when nothing
    /// actionable happened is precisely the cry-wolf failure the cue set exists to
    /// avoid; in ATC an estimated 62-91% of conflict alerts needed no intervention
    /// and controllers learned to distrust them.
    ///
    /// So the SOUND asks a narrower question than the repaint does: did the set of
    /// sessions waiting on you gain a member? nil until the first tick primes it,
    /// so a launch that intakes a backlog stays silent.
    var lastWaitingIds: Set<String>?
    /// The last turn the hail sounded for, as "sessionId:latestId". One hail per
    /// arrival: a tick that re-surfaces the same turn stays quiet — silence after
    /// a hail is "standby", not a request to be hailed again — while a
    /// superseding turn from the same session is a NEW turn and hails anew.
    var lastHailedTurn: String?
    /// The annunciator's last title, so the count logs on change, not per tick.
    var lastMenuBarCount: String?
    /// Consulted only for unprompted surfacing. A keypress is never gated: you
    /// cannot interrupt someone who has just asked for something.
    let gate = InterruptGate(minimumIdleSeconds: 0)

    /// Auditions macOS voices. Long-lived so `stop()` can silence the previous
    /// preview — a per-press instance would leave the old one talking over the new.
    let voicePreview = SystemSpeechProvider()
    /// What the gate decided, and what the room sounded like when it decided it.
    /// Not a log-only rollout — the check is live — but the record is where a
    /// surprising hold gets explained after the fact, which is the whole reason
    /// the thresholds can be provisional.
    let gateLog = GateObservationLog()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance owns the hotkey and the microphone. Two builds running
        // at once BOTH receive the global hotkey and both open the mic —
        // verified 12 Aug: a worktree self-test build launched beside the
        // installed app and every gesture doubled (two 0.80s captures at
        // 16:30:31Z, two replies offered). The bash-side guard lives in
        // relaunch.sh, which a directly-launched worktree build never runs,
        // so the app now defends itself: the newcomer logs the collision and
        // exits before touching the status bar, the hotkey, or the microphone.
        // --allow-second-instance exists for a deliberate side-by-side (none
        // known today); the self-test path needs no exemption because
        // relaunch.sh stops the old instance before launching the new one.
        let myPid = ProcessInfo.processInfo.processIdentifier
        let bundleId = Bundle.main.bundleIdentifier ?? "com.robertnowell.voice-dispatch"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != myPid }
        if !others.isEmpty, !CommandLine.arguments.contains("--allow-second-instance") {
            let pids = others.map { String($0.processIdentifier) }.joined(separator: ", ")
            Permissions.log("launch: REFUSED — instance already running (pid \(pids)); "
                + "pass --allow-second-instance to override")
            exit(1)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Position is a durable fact. Without an autosave name, every relaunch —
        // and this app relaunches dozens of times a day — re-adds the item at
        // the default slot, which on a full menu bar is exactly where macOS
        // hides items first. With it, one ⌘-drag toward the clock survives
        // every relaunch, which is the only real lever against space-droppage
        // (observed 06 Aug: item silently absent, toggles ON in Settings).
        statusItem.autosaveName = "vd-annunciator"
        statusItem.button?.title = StateLegend.menuBarPlaceholder
        // Click → the grid (WS-B, ruled). The menu still exists — permissions,
        // voice, quit — behind a right-click, so the item is never assigned a
        // permanent menu (that would swallow the primary click).
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        rebuildMenu()

        // Build and initialize the capture unit before anyone can press
        // anything, and pre-pay the HAL device start with one start/stop
        // cycle — off the main thread, on the recorder's own queue. The
        // first press then finds warm hardware instead of paying a ~730ms
        // cold start that the old design misclassified as a dead graph.
        recorder.warmUp()

        // Fill the menu's device snapshot before anything draws it, so the
        // first rebuild names a real device rather than blanking for a tick.
        // Detached, because filling it is the very ~50 CoreAudio round trips
        // the snapshot exists to keep off the main actor.
        Task.detached(priority: .utility) { AudioInputDevice.primeCache() }

        // An open that died AFTER start() returned optimistically — the
        // async verification found no audio. The recorder has already torn
        // the capture down; unwind whatever face believed it was live, so
        // the world returns to exactly how the press found it (the same
        // contract the old synchronous throw kept).
        recorder.onCaptureFault = { [weak self] message in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.armedAt = nil
                if self.armedVisually { self.hud.revertArming(because: "mic fault") }
                self.armedVisually = false
                self.handsFreeListening = false
                self.isBusy = false
                self.updateTitle()
                if self.hud.state.ownsStage { self.hud.endCapture(because: "mic fault") }
                self.hud.showResult(message)
            }
        }
        // The machine crossed the wedge threshold: per-press retries stop,
        // start() refuses until the background heal (or a relaunch) proves
        // audio flows again. One honest line, not a storm.
        recorder.onWedge = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastStatusLine = "microphone suspended, capture stack wedged, heal scheduled"
                self.rebuildMenu()
            }
        }

        // The recogniser was the one unobservable stage — a fallback transcript
        // quietly missing its first nineteen seconds looked identical to a short
        // reply (PR #1 harvest). app.log therefore contains what you dictated
        // when the Apple floor runs; README discloses this beside model-calls.
        AppleSpeechRecovery.trace = { Permissions.log("apple-speech: \($0)") }
        // The streaming path's first log lines ever: it failed silently for
        // seven hours on 12 Aug (every session killed by the same server
        // error) and app.log did not contain "assembly" once.
        AssemblyAIStreaming.trace = { Permissions.log("assemblyai: \($0)") }
        AssemblyAIFileRecovery.trace = { Permissions.log("assemblyai-file: \($0)") }
        StreamedUtterance.trace = { Permissions.log("stream: \($0)") }
        CodexThreadNames.trace = { Permissions.log($0) }

        do {
            let store = try QueueStore()
            self.store = store
            // Live transcription: one stream per utterance, keyterms from the
            // shared lexicon. Any stream failure returns nil at finish() and the
            // saved file recovers exactly as before — speed only, never risk.
            recorder.streamFactory = { [weak self] in
                guard let store = self?.store else { return nil }
                let terms = (try? Lexicon.harvest(store: store).terms) ?? []
                return StreamedUtterance(provider: AssemblyAIStreaming(), lexicon: terms)
            }
            self.coordinator = Coordinator(store: store)
            let report = try store.reconcileOnBoot()
            lastStatusLine = report.needsDeliveryCheck.isEmpty
                ? "ready"
                : "\(report.needsDeliveryCheck.count) reply/replies need checking"
        } catch {
            lastStatusLine = "queue unavailable: \(error)"
        }

        // NO automatic transcription retry — ruled 13 Aug, one sweep firing
        // after it shipped. The 5-minute retry sweep lasted exactly one
        // deploy: its first run recovered 1 of 4 failed rows and would have
        // re-uploaded the other three — recordings that genuinely transcribe
        // to nothing — every five minutes forever, because noSpeechDetected
        // leaves a row transcriptionFailed. Failed rows are surfaced for a
        // HUMAN to retry (the menu item, and the recent-audio pane that
        // ruling asked for); the machine does not spend on them unasked.

        // Pull spooled hook events in on a timer. The hook only appends to a file,
        // so nothing is lost while the app is closed — this just moves them across.
        intakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let coordinator = self.coordinator else { return }
                // A dead tap is a mic that cannot be closed and gestures that
                // vanish without a log line. Five seconds is the longest that
                // state gets to exist.
                self.hotkey?.reviveTapIfDead()
                // The annunciator must not vanish silently: macOS drops status
                // items for space with no callback. Detect and say so, once per
                // change — the user can ⌘-drag the item toward the clock (the
                // autosaved position survives relaunches).
                self.checkMenuBarPresence()
                var turnArrived = false
                if let result = try? coordinator.intake(), result.inserted > 0 {
                    // Rows were inserted: a turn came back. This is the honest
                    // trigger. Keying off the count changing missed every arrival
                    // that replaced something — a newer turn superseding an older
                    // one leaves the count identical, and that is the commonest
                    // case of all, because it is what a session doing several turns
                    // in a row looks like.
                    turnArrived = true
                    self.rebuildMenu()
                }
                // Warm the liveness cache off-main first. The probe is a ~0.3s
                // subprocess; called synchronously from the main actor it froze the
                // UI on every tick and every press — which also risks the CGEvent
                // tap timing out, and a timed-out tap is dropped keystrokes.
                await Task.detached { _ = ClaudeAgentsCLI().sessions() }.value
                // And the disk scan, for the same reason one layer over: the
                // grid must never walk the archive on the main thread, and a
                // panel that opens without its closed rows and grows them a
                // moment later is the blink this warm-up exists to prevent.
                //
                // NOT awaited. The liveness probe above is awaited because the
                // very next thing wants an answer from it; this one exists to
                // fill a cache that nothing is blocked on, and awaiting a ~1.4s
                // archive walk here delays everything after it in launch —
                // including the first grid paint, which then lands inside the
                // pendingSend drill's five-second window and gets legitimately
                // refused. The deploy check reads that refusal as a panel stuck
                // holding the stage.
                Task.detached(priority: .utility) { SessionDiscovery.warm() }

                // Write the summary before it is asked for. Doing it on demand meant
                // every use opened with a model call you had to sit through.
                // The prefetch takes the overlay too: without it the app pays
                // for a summary and a voice render on the session you are
                // mid-reply to, for an announcement that must not play.
                try? await coordinator.prepareNext(excluding: self.delivering)

                // Reflect arrivals without being asked. The panel only ever redrew
                // on a keypress, so a session finishing while you were looking
                // straight at it changed nothing and the count went stale. Only
                // while idle: speech, a recording, a countdown or a failure notice
                // are conversations in progress and must not be redrawn under.
                // Housekeeping only — isInFlight gates on the ceiling itself, so
                // an expired entry is already invisible to the lamp. This just
                // stops the map growing across a long-lived app.
                self.delivering.prune()
                // Who a dropped file would go to, refreshed on the tick and
                // read synchronously by render(). Cached rather than resolved
                // per paint because the panel must never wait, and stale by at
                // most one tick is exactly as stale as the grid beside it.
                self.refreshDropTarget()
                let rows = self.sessionRowsNow()
                let waiting = rows.filter { $0.lamp == .ready }.count
                // The menu-bar annunciator refreshes every tick, so its count can
                // never go stale even while the panel stays hidden.
                self.updateTitle()
                // Only on a content change. Redrawing every tick repositions the
                // panel and resets its layout for no reason, which reads as
                // flicker on a window that is meant to sit still. The guard is
                // the row DATA (callsign/topic/lamp), not counts: a topic
                // changing is a change worth painting.
                // Identity, not count: a turn replacing an older turn on the same
                // session leaves both the count and the membership unchanged, and
                // that is exactly the case that should not make a noise.
                let waitingIds = Set(rows.filter { $0.lamp == .ready }.map(\.id))
                let primed = self.lastWaitingIds
                self.lastWaitingIds = waitingIds
                let newlyWaiting = EarconGate.hasNewArrival(waiting: waitingIds, previous: primed)
                let arrived = turnArrived && waiting > 0
                if self.hud.canSurfaceAmbiently,
                   arrived || rows != self.lastShownRows {
                    if arrived {
                        self.surfaceArrival(rows: rows, waiting: waiting,
                                            newlyWaiting: newlyWaiting)
                    }
                    // Currency is not attention. Whatever the attention gates
                    // decided (held, frontmost-skip), lamps that are on screen
                    // must be true — a stale green is the instrument lying. And
                    // the guard records PAINTS, not computations: a skipped
                    // paint retries next tick instead of certifying itself
                    // (the 23:39 lock-in: frontmost-skip threw the rows away
                    // AFTER the guard had already recorded them). Never raises
                    // the panel: visible-and-idle only; a decrease stays quiet.
                    if self.hud.isOnScreen, self.hud.canSurfaceAmbiently {
                        self.hud.showIdle(rows: rows)
                        self.lastShownRows = rows
                        // The glow lives HERE, with the repaint, not with the
                        // hail — measured 11 Aug, watching a real arrival while
                        // collapsed produce nothing at all.
                        //
                        // It was inside `surfaceArrival`, behind two returns
                        // meant for the away-channel: the interrupt gate, and
                        // the frontmost-tab skip. Both are about whether to
                        // INTERRUPT you. A panel you have chosen to keep on
                        // screen updating its own contents is not an
                        // interruption — it is the same class of thing as the
                        // lamp turning green two lines up, which those gates
                        // have never suppressed and should not.
                        if arrived, let lit = rows.first(where: { $0.lamp == .ready })?.lamp {
                            self.hud.flashArrival(lit)
                        }
                    }
                }
            }
        }

        // Lifted ABOVE the hotkey on purpose (ruled 18 Aug). A screenshot
        // tool has no business installing a global event tap: `--pose-shot`
        // renders one face, writes a PNG and exits, and it used to do all that
        // AFTER `HotkeyMonitor` was live — so taking a picture of the panel
        // while the real app was running put two taps on one chord for the
        // second it took, which is the collision relaunch.sh exists to prevent.
        // Nothing below this line is needed to draw a face.
        // Dev tooling: `--pose <name>` renders exactly one panel state with
        // representative data and holds it until the process is killed. The
        // whole launch tail is skipped — intake, permission polling, the
        // microphone request, the idle repaint — so nothing ever advances or
        // repaints over the posed face. See StatusHUD.pose for the states.
        if let flag = CommandLine.arguments.firstIndex(of: "--pose"),
           flag + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments[flag + 1]
            intakeTimer?.invalidate(); intakeTimer = nil
            if hud.pose(name) {
                Permissions.log("pose: holding \(name) until killed")
            } else {
                Permissions.log("pose: unknown name '\(name)'")
            }
            return
        }

        // One-shot: pose a face, photograph it FROM the view hierarchy, exit.
        // No Screen Recording grant, no awake display — the pose renders its
        // own pixels, so this works from a lidded laptop or a headless agent.
        if let flag = CommandLine.arguments.firstIndex(of: "--pose-shot"),
           flag + 2 < CommandLine.arguments.count {
            let name = CommandLine.arguments[flag + 1]
            let path = CommandLine.arguments[flag + 2]
            intakeTimer?.invalidate(); intakeTimer = nil
            let posed = hud.pose(name)
            if posed {
                // A pose that resizes the panel from whatever it already
                // showed animates over 0.12s (resizeToFit, when the panel is
                // already visible) — found posing "agents-settings" 25 Aug:
                // poseSnapshot() reads pixels synchronously, right after
                // pose(name) returns, so without this it photographs the
                // frame mid-animation and the new content is clipped off the
                // bottom, silently. `Thread.sleep` was the first fix tried and
                // does NOT work — it blocks the very run loop
                // NSAnimationContext needs to advance the animation at all,
                // so the frame is exactly as stale after a slept 0.25s as
                // before it. Spinning the run loop instead actually lets the
                // animation run and land.
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
            if posed, let png = hud.poseSnapshot() {
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    Permissions.log("pose-shot: \(name) → \(path) (\(png.count) bytes)")
                } catch {
                    Permissions.log("pose-shot: write failed: \(error)")
                }
            } else {
                Permissions.log("pose-shot: nothing rendered for '\(name)'")
            }
            NSApp.terminate(nil)
            return
        }


        hotkey = HotkeyMonitor { [weak self] transition in
            if case .pauseToggled = transition {
                // Pause is an AUDIO behavior (simplification pass, ruled): the
                // visual stays the frozen speaking card — the highlight stopped
                // mid-word IS the pause indication. No pill switch, no hint.
                Task { @MainActor in
                    guard let self, let speech = self.coordinator?.speech,
                          speech.isSpeaking || speech.isPaused else { return }
                    speech.togglePause()
                }
                return
            }
            // The tap callback runs on the main run loop, but hop explicitly so the
            // compiler agrees and so this stays correct if the tap ever moves.
            Task { @MainActor in self?.handle(transition) }
        }

        // The panel can drive a recording itself, so answering never depends on
        // knowing a hotkey that is invisible in the UI.
        // The gear lands on the first tab. Settings is a tabbed pane now, and
        // opening on the tab that is not first is the kind of small lie that
        // makes a tab bar feel decorative.
        hud.onOpenSettings = { [weak self] in self?.hud.showAgentSettings() }
        // The separate waiting-list face is gone: the idle grid IS the list.
        hud.onPickWaiting = { [weak self] id in self?.announceNext(only: id) }
        hud.onNewSession = { [weak self] in self?.newSession() }
        hud.onRevive = { [weak self] id, name in self?.revive(id, name: name) }
        // Ruled 13 Aug on the Past Agents face, moved to the grid 16 Aug: the
        // right-click ends the session. SIGTERM first — a Claude session dies
        // clean and stays resumable — escalating only if it has to, and never
        // touching the terminal tab, which stays open at its shell prompt
        // because the shell is in a different process group and we address the
        // agent's own (see SessionTermination).
        //
        // The old shape sent one signal and logged that it had sent it, which is
        // a receipt for a signal rather than for a death. Everything below the
        // ladder is about the row: the six-second liveness cache is dropped and
        // the grid rebuilt, so the lamp goes out while the user's hand is still
        // on the mouse instead of up to six seconds later, which reads as a
        // click that did nothing.
        //
        // Probe, signal and poll off-main (rule 9); only the repaint hops back.
        hud.onTerminateSession = { [weak self] id, name in
            Task.detached {
                // `agents` alone made this a permanent no-op for a live Codex
                // session (26 Aug) — logged "already gone" and refused to
                // terminate a process that was, in fact, still running.
                guard let live = ((ClaudeAgentsCLI().sessions() ?? [])
                    + FileSessionOwnershipStore.shared.liveNonRegistrySessions())
                    .first(where: { $0.sessionId == id }) else {
                    Permissions.log("terminate: \(name) (\(id.prefix(8))) not in agents — already gone")
                    await MainActor.run { self?.refreshGridAfterTerminate() }
                    return
                }
                // The tty the session was seen on, handed to the ladder as the
                // second half of its identity guard.
                let outcome = SessionTermination.end(
                    pid: live.pid, named: name,
                    expectedTty: ProcessProbe.tty(of: live.pid),
                    // The harness comes off the session, not off a default.
                    // With a default it took Claude's, and the guard refused
                    // every Codex row: "pid 46356 is `codex`, not a claude
                    // session", logged and invisible, three times in thirty
                    // seconds while Robert clicked End (31 Aug).
                    expectedCommand: KnownHarnesses.adapter(for: live.harness)
                        .processCommandFragment)
                switch outcome {
                case .refused(let why):
                    Permissions.log("terminate: \(name) NOT ended — \(why)")
                case .survived:
                    Permissions.log("terminate: \(name) (pid \(live.pid)) survived "
                        + "SIGTERM and SIGKILL, it is wedged, and nothing else can be sent")
                case .alreadyGone, .died:
                    break   // SessionTermination.trace has already said it
                }
                await MainActor.run { self?.refreshGridAfterTerminate() }
            }
        }
        hud.onOpenPastAgents = { [weak self] in self?.openPastAgents() }
        // A live session does not need reviving — it needs finding, which is
        // the same door the card's GO TO AGENT opens.
        hud.onGoToSession = { [weak self] id in self?.goToSession(id) }
        hud.onNewSessionForArtifact = { [weak self] ref in
            self?.newSession(forArtifact: ref)
        }
        // The card's second door, and the other direction of the same
        // correlation the footer opens: the page links back to its agent, and
        // the agent's card opens what the turn calls for — the report this
        // turn just wrote when there is one, the hub otherwise. The label
        // follows the destination (ruled 15 Aug, refining the hub-door ruling
        // of the same day); the hub stays one click away either way, via the
        // report's own "Open hub" footer button.
        // The card asks, the app answers from what the grid already knows.
        hud.harnessForSession = { [weak self] id in self?.harnessById[id] }
        hud.doorForSession = { [weak self] session in
            if let report = self?.freshReport(session: session) {
                return .report(report)
            }
            return HomeBase.existingPage(sessionId: session) != nil ? .hub : nil
        }
        hud.onOpenHub = { [weak self] session in
            _ = self?.openHub(session: session)
        }
        hud.onOpenReport = { page in
            let url = URL(fileURLWithPath: page)
            if BrowserFocus.focusExistingTab(url) == .notFound {
                NSWorkspace.shared.open(url)
            }
        }
        // The signature. Same door mechanics as the pages above it — raise the
        // tab that already has it rather than making tab twenty-nine — except
        // that it does NOT reload: the repository is a live page nobody here
        // rewrote, so a reload would throw away whatever the user was reading
        // on it. This is the caller `reloading: false` was left in for.
        hud.onOpenRepository = {
            let url = StateLegend.repositoryURL
            if BrowserFocus.focusExistingTab(url, reloading: false) == .notFound {
                NSWorkspace.shared.open(url)
            }
        }
        // The drop tray's three wires (docs: the panel takes files).
        //
        // Answered from a CACHED tuple, never a live probe: render() calls
        // this on every repaint, and resolveReplyContext shells out to
        // `claude agents --json` for a pid the tray does not need. Rule 9 —
        // the main actor draws, it does not wait on a subprocess.
        hud.replyTargetForDrop = { [weak self] in self?.dropTarget }
        hud.stagedFiles = { [weak self] session in
            self?.coordinator?.attachments.staged(for: session) ?? []
        }
        hud.onUnstage = { [weak self] session, path in
            self?.coordinator?.attachments.unstage(path, session: session)
        }
        hud.onFilesDropped = { [weak self] items in
            guard let self, let coordinator, let target = dropTarget else {
                // Refused rather than swallowed. The overlay never appears
                // without a target, so this is the race where the last
                // session died mid-drag — say so instead of eating the file.
                self?.lastStatusLine = "nothing to attach to yet"
                Permissions.log("drop: refused, no reply target")
                return false
            }
            var staged = 0
            for item in items {
                switch item {
                case .file(let path):
                    if coordinator.attachments.stage(path, session: target.sessionId) {
                        staged += 1
                    }
                case .imageData(let data, let ext):
                    // A drag out of a browser has no file behind it. It goes
                    // to disk BEFORE it is staged — a chip pointing at bytes
                    // that live only in a pasteboard would break the moment
                    // the drag ended, and the session needs a path it can
                    // actually open. Content-hashed, so re-dropping the same
                    // image is the same chip rather than a second copy.
                    guard let path = Self.persistDroppedImage(data, ext: ext) else {
                        Permissions.log("drop: could not persist \(data.count) bytes")
                        continue
                    }
                    if coordinator.attachments.stage(path, session: target.sessionId) {
                        staged += 1
                    }
                }
            }
            guard staged > 0 else {
                lastStatusLine = "already attached"
                return true    // taken, just nothing new — never an error badge
            }
            let total = coordinator.attachments.staged(for: target.sessionId).count
            lastStatusLine = "\(staged) file\(staged == 1 ? "" : "s") attached to \(target.label)"
            Permissions.log("drop: staged \(staged) for "
                            + "\(target.sessionId.prefix(8)) (\(total) total)")
            // A drop during the undo window changes THIS message, not a
            // mysterious future one. Core binds the newly staged paths to the
            // pending utterance; the HUD refreshes the exact text that will be
            // sent without replacing or restarting its one countdown.
            if let utteranceId = hud.pendingSendUtteranceId,
               let text = try? coordinator.refreshPendingSend(
                    utteranceId: utteranceId, sessionId: target.sessionId) {
                hud.updatePendingSendText(text, utteranceId: utteranceId)
            }
            rebuildMenu()
            return true
        }
        hud.onBreadcrumbHome = { [weak self] in self?.goHomeFromCard(via: "breadcrumb") }
        hud.onPendingSendStopped = { [weak self] cardRestored in
            // Don't send has landed the panel somewhere alive. A restored card
            // gets its dwell clock back (ruling 14's shape — same as the arm
            // revert); a readback that was the whole panel yields to the grid
            // it was covering.
            if cardRestored { self?.scheduleReturnToGrid() }
            else { self?.showIdleGrid() }
        }
        hud.onClearLamp = { [weak self] id in
            guard let self, let coordinator = self.coordinator else { return }
            // "Mischief managed" (ruled 06 Aug): the lamp click means "I don't
            // care about this one" — heard, not announced, not invited. Same
            // cursor write a played announcement lands on, so nothing new to
            // reconcile.
            if let target = try? coordinator.waiting().first(where: { $0.sessionId == id }) {
                // Dismiss, not markHeard: the click means "I don't care about
                // this one" — a decision about attention, not a claim to have
                // heard it. Dismissal removes the row from waiting() outright;
                // the announce path never sees it again either.
                try? coordinator.dismiss(sessionId: id, through: target.latestId)
                Permissions.log("lamp: cleared \(target.callsign ?? id.prefix(8).description) by click")
            }
            // And the row leaves the grid (18 Aug). Dismissal alone was only
            // ever half of what the gesture means: it silences the TURN, and
            // the user is switching off the SESSION. Both, or a green row you
            // just filed sits there quietly, still on the panel.
            LampSwitch.turnOff(id)
            Permissions.log("lamp: switched off \(id.prefix(8)) — filed to past agents")
            self.showIdleGrid()
        }
        // The other half of the switch: the list hands a session back.
        // No process work at all — this row's agent has been running the whole
        // time — so unlike revive there is nothing to launch, wait for, or
        // announce. It is a line in a file and a repaint.
        hud.onRestoreLamp = { [weak self] id in
            LampSwitch.turnOn(id)
            Permissions.log("lamp: switched on \(id.prefix(8)) — back on the grid")
            self?.showIdleGrid()
        }
        hud.onLeaveSettings = { [weak self] in
            guard let self else { return }
            self.coordinator?.speech.stop()
            self.showIdleGrid()
        }

        hud.onPreviewVoice = { [weak self] id in
            guard let self else { return }
            // Silence the last preview first. Auditioning voices means switching
            // fast, and without this each pick layered onto the one before it,
            // which is the one thing this app must never do.
            self.coordinator?.speech.stop()
            // Play the real thing. A stock sample tells you how a voice handles a
            // stock sentence; what you actually want to know is how it handles YOUR
            // summaries, which are dense, full of proper nouns, and end in a question.
            // Preview only — the narrator (VoiceCatalog.selectedVoiceId) is not
            // touched; the roster check is what changes who speaks for sessions.
            Task { @MainActor in
                // A row for a voice that is not installed cannot be auditioned, so
                // pressing it does the thing you actually wanted: opens the page that
                // downloads it. The row is the button.
                if SystemVoiceCatalog.isDownloadRow(id) {
                    if let url = URL(string: SystemVoiceCatalog.settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                    self.lastStatusLine = "Settings → \(SystemVoiceCatalog.remainingSteps)"
                    return
                }
                let sample = SpokenTextSanitizer().sanitize(self.previewText())
                // A macOS voice cannot be auditioned through the ElevenLabs path.
                // `chain.speak(voice:)` takes an ElevenLabs id; handed a system
                // identifier it recognised nothing, fell through to the single system
                // provider, and that provider spoke in ITS configured voice — so every
                // row played the same voice and the picker was unusable.
                if SystemVoiceCatalog.isSystemVoice(id) {
                    // One long-lived provider rather than one per press, so the
                    // `stop()` above actually silences the previous preview. A fresh
                    // instance each time would leave the old one talking.
                    self.voicePreview.stop()
                    self.voicePreview.voiceIdentifier = id
                    try? await self.voicePreview.speak(sample, onWord: nil)
                } else {
                    guard let chain = self.coordinator?.speech else { return }
                    _ = await chain.speak(sample, voice: id)
                }
            }
        }

        // A checked voice goes to the roster it BELONGS to. This one function is
        // where the 400 loop came from: the pane lists both families, and this
        // appended whatever was checked to the single ElevenLabs roster, so
        // checking a system voice put an Apple identifier into the cloud
        // rotation. Routing by id family is the whole fix, and it makes the bug
        // unreachable rather than merely unlikely.
        hud.onToggleVoice = { [weak self] id, nowOn in
            guard let self else { return }
            let system = SystemVoiceCatalog.isSystemVoice(id)
            var roster = (system ? VoiceRoster.loadSystem() : VoiceRoster.load())
                .filter { $0 != id }
            if nowOn { roster.append(id) }
            if system { VoiceRoster.saveSystem(roster) } else { VoiceRoster.save(roster) }
            self.hud.updateSettings(roster: Self.checkedVoices())
            Permissions.log("roster: \(nowOn ? "added" : "dropped") \(id) to the "
                            + "\(system ? "system" : "ElevenLabs") roster "
                            + "(\(roster.count) on it)")
        }

        hud.onRosterReordered = { ids in
            // One drag reorders one family; the other roster's order is untouched.
            VoiceRoster.save(ids.filter { !SystemVoiceCatalog.isSystemVoice($0) })
            VoiceRoster.saveSystem(ids.filter(SystemVoiceCatalog.isSystemVoice))
            Permissions.log("roster: reordered to \(ids.count) entries across both rosters")
        }

        hud.onShowRecentAudio = { [weak self] in self?.showRecentAudio() }
        // One door per pane. The panel asks for a tab; the host assembles that
        // tab's data and shows it. Nothing re-renders a pane it has not fed.
        hud.onOpenSettingsTab = { [weak self] tab in
            guard let self else { return }
            switch tab {
            case .agents: hud.showAgentSettings()
            case .setup: hud.showSetupSettings()
            case .voices: openSettings(tab: .voices)
            case .recent: showRecentAudio()
            }
        }
        hud.onDefaultHarnessChanged = { [weak self] in self?.rebuildMenu() }

        // Play carries its state on the row (▶/■), so the player reports
        // every change and the pane re-renders from the store + playingId —
        // one source of truth, no view-side state.
        utterancePlayer.onStateChange = { [weak self] in
            guard let self else { return }
            self.hud.updateRecentAudio(events: self.recentAudioEvents())
        }
        hud.onPlayAudioEvent = { [weak self] id in
            guard let self, let store = self.store,
                  let row = try? store.utterances(limit: 200).first(where: { $0.id == id }),
                  let path = row.audioPath, FileManager.default.fileExists(atPath: path)
            else {
                Permissions.log("recent-audio: no audio on disk to play")
                return
            }
            self.utterancePlayer.toggle(id: id, path: path)
        }

        hud.onRevealAudioEvent = { [weak self] id in
            guard let self, let store = self.store,
                  let row = try? store.utterances(limit: 200).first(where: { $0.id == id }),
                  let path = row.audioPath, FileManager.default.fileExists(atPath: path)
            else {
                Permissions.log("recent-audio: no audio on disk to reveal")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            Permissions.log("recent-audio: revealed \(id.prefix(8)) in Finder")
        }

        // A row's ↻ — the ONLY path that retries a transcription (ruled
        // 13 Aug: humans retry, the machine does not). Mark the row spent,
        // run the chain over its saved audio, re-render with whatever the
        // store now says. The heavy halves (decode, network, recognition)
        // are nonisolated async — rule 9 holds.
        hud.onRetryAudioEvent = { [weak self] id in
            guard let self, let store = self.store else { return }
            self.hud.updateRecentAudio(events: self.recentAudioEvents(retrying: id))
            Task { @MainActor in
                do {
                    if let updated = try await store.retryTranscription(utteranceId: id) {
                        Permissions.log("recent-audio: retried \(id.prefix(8)) → "
                            + "\(updated.transcriptText.map { "\($0.count) chars" } ?? "no transcript") "
                            + "(\(updated.transcriptProvider ?? "no provider"))")
                    } else {
                        Permissions.log("recent-audio: \(id.prefix(8)) has no audio to retry")
                    }
                } catch {
                    Permissions.log("recent-audio: retry \(id.prefix(8)) failed: \(error)")
                }
                self.hud.updateRecentAudio(events: self.recentAudioEvents())
            }
        }

        hud.onDismiss = { [weak self] in
            guard let self else { return }
            self.coordinator?.speech.stop()
            GreetingCache.stop()
            self.isAnnouncing = false
            if self.recorder.isRecording { _ = try? self.recorder.stop() }
            self.handsFreeListening = false
            self.recordingDestination = nil
            self.isBusy = false
            // Dismiss means the item is done with — not "hide the window and leave
            // it in the queue", which is what made the button meaningless.
            if let sessionId = self.hud.currentEventId { self.dismissCurrent(sessionId) }
            self.activeConversation = nil
            self.updateTitle()
            self.rebuildMenu()
        }

        // hud.onReply / hud.onStopReply are dead (simplification pass): they
        // existed for the panel's Reply button, and the button rows are gone —
        // chords are the interface (hold ⌥ / ⌥⌥ hands-free / deep links).

        // Existing installations were created before storage was private by
        // default, so their modes are only fixed by doing it explicitly at startup.
        // `QueueStore.supportDirectory`, so the isolated test build hardens
        // its OWN directory rather than reaching into the real app's.
        PrivateStorage.harden(directory: QueueStore.supportDirectory)

        ElevenLabsSpeechProvider.trace = { Permissions.log("11labs: \($0)") }
        // Populate the picker from the account rather than a hardcoded list.
        Task { @MainActor in
            _ = await VoiceCatalog.refresh()
            self.rebuildMenu()
        }
        Coordinator.trace = { Permissions.log("routing: \($0)") }
        TmuxTransport.trace = { Permissions.log($0) }
        // The ownership lookup's own evidence. Without it, a session killed
        // for being "hand-started" leaves only the conclusion in the log and
        // no way to tell a real absence from a question that timed out.
        Tmux.trace = { Permissions.log($0) }
        ClaudeAgentsCLI.trace = { Permissions.log("liveness: \($0)") }
        SessionLauncher.trace = { Permissions.log("launcher: \($0)") }
        Recorder.trace = { Permissions.log($0) }
        Recorder.onListeningAcknowledged = { Earcons.acknowledge(.listening) }
        SessionTermination.trace = { Permissions.log($0) }
        Secrets.trace = { Permissions.log("secrets: \($0)") }
        QueueStore.trace = { Permissions.log("queue: \($0)") }
        Permissions.log("args=\(CommandLine.arguments)")
        // Say out loud whether the thing this app depends on is actually wired.
        //
        // Nothing checked before, and the hook contract is to exit 0 whatever happens
        // — so a renamed or moved script is indistinguishable from a healthy one. That
        // is how events stopped for 37 minutes during active use with no symptom but
        // lamps that would not turn green, and how `artifact-hook` shipped and sat
        // uninstalled without ever being mentioned.
        // One roster became two (20 Aug). Runs before anything reads either, and
        // is a no-op on every launch after the first.
        if let split = VoiceRoster.splitMixedRoster() {
            Permissions.log("roster: split one mixed roster into "
                            + "\(split.cloud) ElevenLabs + \(split.system) system voices")
        }

        if let problem = HookManifest.machineSummary() {
            // Repair, not just report (Robert, 12 Aug: "nobody ever wants to
            // run a command — we either keep it up to date or give them one
            // click"). The repair is bounded to entries carrying our markers,
            // backs the file up first, and its receipt is a re-audit. When it
            // cannot repair — no healthy entry and no recorded directory to
            // learn from — noticing remains the floor, said out loud, because
            // a hook's own contract (exit 0 whatever happens) means nothing
            // else ever will.
            Permissions.log("startup: \(problem)")
            // EVERY harness this machine has. The old call repaired one
            // hardcoded file and its note said "New Claude Code sessions pick
            // them up automatically" — accurate, and on a two-harness machine
            // that sentence was the app quietly reporting what it had not done.
            var repairedHarnesses: [String] = []
            for (harness, outcome) in HookManifest.repairAll() {
                switch outcome {
                case .healthy:
                    Permissions.log("startup: \(harness.id) hooks healthy on re-audit")
                case .repaired(let rewired, let added):
                    Permissions.log("startup: \(harness.id) hooks repaired — "
                        + "\(rewired) rewired, \(added) added")
                    repairedHarnesses.append(harness.label)
                case .unavailable(let reason):
                    Permissions.log("startup: \(harness.id) hooks NOT repaired — \(reason)")
                    hud.note("\(harness.label) hooks need attention: \(reason)")
                }
            }
            if !repairedHarnesses.isEmpty {
                hud.note("Hooks were out of date, fixed for "
                    + repairedHarnesses.joined(separator: " and ")
                    + ". New sessions pick them up automatically.")
            }
        } else {
            Permissions.log("startup: hooks installed and reachable")
        }

        // Look at the checklist without launching a second live instance.
        //   TranquilityApp --dump-onboarding /tmp/gate.png
        if let i = CommandLine.arguments.firstIndex(of: "--dump-onboarding"),
           i + 1 < CommandLine.arguments.count {
            // Optional third argument names a scenario, so the states a
            // developer machine cannot reach are still reviewable:
            //   --dump-onboarding /tmp/a.png fresh|midway|done
            if i + 2 < CommandLine.arguments.count {
                switch CommandLine.arguments[i + 2] {
                case "fresh":
                    Permissions.previewStates = [.microphone: .notAsked,
                                                 .speechRecognition: .notAsked,
                                                 .inputMonitoring: .notAsked,
                                                 .accessibility: .notAsked]
                case "midway":
                    Permissions.previewStates = [.microphone: .active,
                                                 .speechRecognition: .notAsked,
                                                 .inputMonitoring: .pendingRestart,
                                                 .accessibility: .denied]
                case "stuck":
                    // The state this whole change exists for: a restart was
                    // asked for, the user did it, and nothing changed.
                    Permissions.previewStates = [.microphone: .active,
                                                 .speechRecognition: .active,
                                                 .inputMonitoring: .stale,
                                                 .accessibility: .active,
                                                 .automation: .active]
                default: break
                }
            }
            onboarding.writePreview(to: CommandLine.arguments[i + 1])
            NSApp.terminate(nil)
            return
        }
        // The grid as it really is, from live data, photographed and gone.
        //   TranquilityApp --allow-second-instance --live-grid-shot /tmp/g.png
        //
        // `--pose-shot grid` draws FIXTURES, which is right for chrome and
        // useless for "does a Codex row have a name today". Added 30 Aug after
        // shipping a name fix that could only be checked by asking Robert to
        // look at his own screen.
        // Past Agents from live data, same reason as --live-grid-shot: the
        // question "is a given Codex session in this list today" cannot be
        // answered by a fixture.
        if let i = CommandLine.arguments.firstIndex(of: "--past-agents-shot"),
           i + 1 < CommandLine.arguments.count {
            // The grid first, which is what builds the panel. Going straight
            // to Past Agents crashes on an unbuilt `pastList`, and it is also
            // not a path a person can take: you are always on the grid before
            // you press PAST AGENTS.
            showIdleGrid()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            // Long enough for the archive walk to land. `discoverIfScanned`
            // returns nothing on a cold cache by design, and a fresh instance
            // photographed a second in shows "0 sessions" for that reason
            // alone, which would read as a bug in the list.
            if !CommandLine.arguments.contains("--cold") {
                SessionDiscovery.warm()
            }
            openPastAgents()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            openPastAgents()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            if let png = hud.poseSnapshot() {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                Permissions.log("past-agents-shot: wrote \(CommandLine.arguments[i + 1])")
            } else {
                Permissions.log("past-agents-shot: nothing rendered")
            }
            NSApp.terminate(nil)
            return
        }
                if let i = CommandLine.arguments.firstIndex(of: "--live-grid-shot"),
           i + 1 < CommandLine.arguments.count {
            showIdleGrid()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if let png = hud.poseSnapshot() {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                Permissions.log("live-grid-shot: wrote \(CommandLine.arguments[i + 1])")
            } else {
                Permissions.log("live-grid-shot: nothing rendered")
            }
            NSApp.terminate(nil)
            return
        }
                if CommandLine.arguments.contains("--show-onboarding")
            || CommandLine.arguments.contains("--show-prerequisites") {
            onboarding.show { }
        }
        if CommandLine.arguments.contains("--selftest-hud") {
            refreshIsCheapDrill()
            permissionSurfacesDrill()
            hud.selfTest()
            // Before selfTestPendingSend: that one holds the panel for five more
            // seconds and releases the drill hold when it is done.
            hud.selfTestReadbackDoor()
            hud.selfTestPendingSend()
            // The voice-menu cache drill (issue 14, nested blocker). By the
            // time this checks, the snapshot must be warm, the menu must
            // carry the Voice submenu, and a rebuild must be quick even with
            // the catalogue populated — the tick never again pays the TTS
            // daemon's price.
            //
            // Polls until the snapshot has actually loaded rather than
            // sleeping a fixed duration and hoping — fixed at a flat 4s
            // until 24 Aug, when this drill started failing identically on
            // `main` and this branch the same afternoon on builds whose
            // panel source was byte-identical (2026-08-24-tb-state-on-the-
            // arc). A fixed sleep races an off-thread load with no
            // completion signal, so any machine (or TTS daemon) slower than
            // whatever the deadline was tuned against fails through no
            // fault of the build — measuring the hour, not the build, the
            // same class of flake this drill's own doc comment already
            // records being fixed once before in the sibling assertion
            // below. Bounded at 10s (the old deadline, well doubled) so a
            // genuinely broken loader still fails the drill rather than
            // hanging the launch.
            Task { @MainActor in
                var warm = false
                for _ in 0..<50 {
                    if !SystemVoiceCatalog.cachedRows().catalogue.isEmpty { warm = true; break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                // TWO rebuilds, and the gate reads the second (18 Aug).
                //
                // The drill's name is "cacheWarm" and its assertion was
                // "warmRebuildIsQuick", but nothing here guaranteed the
                // measured rebuild WAS warm: it raced whatever else had
                // rebuilt the menu since launch, and it failed 9 of 24
                // deploys, in both directions, on builds whose panel source
                // was byte-identical. A drill that flips on an identical
                // binary is measuring the hour, not the build — and a gate
                // that is red a third of the time teaches everyone to read
                // past a red gate, which costs more than the drill is worth.
                //
                // So the first rebuild pays whatever one-time price exists
                // and is REPORTED, not asserted; the second is the warm one
                // and is what the gate reads. The section split says which
                // part of the function spent the time, because measuring it
                // from outside the app ruled out every candidate the
                // comments here name: the rows cache never blocks a reader
                // (its loader runs on a global queue and the lock only
                // guards assignments), the ElevenLabs cache file reads in
                // 0.11 ms, and the CoreAudio resolves cost 5 to 9 ms with a
                // Bluetooth device connected. What is left is a first-menu
                // cost of 125 to 300 ms, which is the right magnitude for
                // the slow mode and is exactly what a first-versus-second
                // measurement tells apart.
                let cold = self.timedRebuildMenu()
                let hot = self.timedRebuildMenu()
                SelfTest.report("voiceMenu.cacheWarm", [
                    ("snapshotLoaded", warm),
                    // statusMenu, not statusItem.menu: the item's menu slot is
                    // deliberately nil except during a right-click, so the
                    // built menu lives in the property (caught by this drill's
                    // own first deploy reading the wrong one).
                    ("voiceSubmenuBuilt",
                     self.statusMenu?.items.contains { $0.title == "Voice" } ?? false),
                    ("warmRebuildIsQuick", hot.total < 50),
                ])
                Permissions.log(
                    "selftest voiceMenu: warm rebuild \(Int(hot.total))ms "
                    + "(voices \(Int(hot.voices)), mic \(Int(hot.mic))) · "
                    + "first rebuild \(Int(cold.total))ms "
                    + "(voices \(Int(cold.voices)), mic \(Int(cold.mic)))")
            }
            // The mic drill asks the one question a deploy can answer without
            // opening the real microphone (that boundary is relaunch.sh's,
            // stated where it excludes --selftest-arm): did warm-up leave the
            // machine WARM — unit built, initialized, device bound, HAL start
            // prepaid? Scheduled off the drill path because warmUp runs on
            // the recorder's own queue; three seconds is far past its worst
            // case. SKIP (not PASS) without the mic grant: an unauthorized
            // machine proves nothing either way. The table's own legality is
            // proven in Core by MicMachineTests, not re-drilled here.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard Recorder.microphoneAuthorized() else {
                    Permissions.log("selftest mic: SKIP — microphone not granted")
                    return
                }
                SelfTest.report("mic", [
                    ("warmAtRest", self.recorder.micStateName == "warm"),
                    ("autoArmOpen", self.recorder.allowsAutoArm),
                ])
            }
        }

        // Instant-arm evals E2/E4/E5 (docs/instant-arm.md), driven through the
        // real handler with the real recorder and store. Needs the microphone
        // grant; logs SKIPPED honestly when it is absent.
        if CommandLine.arguments.contains("--selftest-arm") {
            Task { @MainActor in
                // Let launch settle: first idle paint, permission poll.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.runArmSelftest()
            }
        }

        // Drive the real speech chain end to end so the highlight can be checked
        // from code instead of from a screenshot.
        if CommandLine.arguments.contains("--selftest-speak") {
            let text = SpokenTextSanitizer().sanitize(
                "Testing the word highlight. The second sentence should light up after the first.")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                hud.showAnnouncement(spoken: text,
                                     sessionId: "selftest", pid: nil,
                                     project: "tranquility-base", cwd: nil)
                _ = await SpeechChain().speak(text, onWord: { [weak self] range in
                    Task { @MainActor in self?.hud.highlight(upTo: range.upperBound) }
                })
                Permissions.log("selftest-speak finished")
            }
        }

        // The checklist's restart question is answered by the live tap, not by
        // a table of which permissions "need a restart" — see `Permissions.State`.
        Permissions.listeningProbe = { [weak self] in self?.hotkey?.isListening ?? false }
        // The real registration attempt for Input Monitoring, run from the
        // checklist's own Grant button. See `Permissions.startListening`'s
        // own doc comment for why this is needed at all.
        Permissions.startListening = { [weak self] in _ = self?.hotkey?.start() }

        startPermissionPolling()
        startWatchingForRevokedPermissions()
        refresh()

        // NOTHING asks for a permission at launch any more. Reported
        // directly, 26 Aug, against the very build meant to fix this class
        // of complaint: "it shouldn't ask for any permissions before the
        // user clicks grant." This block used to call
        // `Permissions.request(.microphone)` unconditionally right here,
        // which fired the system's own microphone dialog before the
        // checklist window had even painted, over an app that, from the
        // user's side, had shown nothing yet. The concern that motivated
        // the original call, that an app which has never asked is not
        // listed in the Microphone pane at all, is still satisfied, just
        // later: the FIRST press of that row's own Grant button
        // (`grantTapped`, OnboardingWindow.swift) is what registers it,
        // which is also the first moment a person actually asked for it.
        //
        // `allActive`, not `allGranted`: a permission granted while the
        // app was already running can be recorded by macOS and still
        // unusable here, and the grid must never be the thing shown in
        // that state, because it cannot hear or dispatch anything.
        // Reported directly, also 26 Aug, by a three-months user whose own
        // relaunch landed mid-permission-grant: "if critical permissions
        // are ever missing you should show the onboarding screen not the
        // grid because the grid won't work."
        Permissions.logEnvironment()
        if Permissions.allActive {
            // Visible proof of life. A menu-bar-only app with a full menu
            // bar is indistinguishable from a broken one; this makes
            // launch observable.
            showIdleGrid()
        } else {
            onboarding.show { [weak self] in
                self?.refresh()
                self?.showIdleGrid()
            }
        }
    }

    /// A2 — the hail. A turn arrived and the panel surfaced for it; say WHO and
    /// stop: a minor chime, then just the callsign through the normal speech
    /// chain. The content waits for ⌃⌥ ("go ahead"). Nothing is marked heard and
    /// no cursor moves, so standby — saying nothing — loses nothing: the grid row
    /// stays lit and ⌃⌥ later plays the full summary exactly as before.
    ///
    /// The voice is the away-channel, and this is its ONLY unprompted use in the
    /// app. It never interrupts: if anything is already speaking (or the
    /// microphone is open), the surfaced panel and the lit lamp ARE the hail and
    /// the audio is skipped — a hail that talks over another utterance would be
    /// the app interrupting itself to say less.
    /// Home from a card, by any door — ⌃⌥ or the clicked breadcrumb (ruled
    /// 06 Aug: voiced first, but the pointer works too). Stops the voice and
    /// returns to the grid, advancing NOTHING: no dismissal, no markHeard, no
    /// next announcement. A mid-speech stop also wakes the announce task,
    /// whose `.interrupted` arm repaints the grid with its own note; painting
    /// it now covers the already-finished card too.
    func goHomeFromCard(via door: String) {
        Permissions.log("\(door): home")
        // Leaving DURING Preparing is the one door out that has to reach into
        // the announcement itself. Nothing has been spoken yet, so stopping the
        // voice stops nothing: the task is still summarizing, and it would
        // arrive seconds later and paint its card over the grid you just asked
        // for — a back button that appears not to have worked, twice.
        //
        // Only from preparing. From `.speaking` the audio IS the task's
        // progress, so `speech.stop()` already ends it through the interrupted
        // path, which is what leaves the "Stopped." note the user reads.
        // Cancelling there would silence that receipt as well as the voice.
        if case .preparing = hud.state {
            announceTask?.cancel()
            announceTask = nil
        }
        coordinator?.speech.stop()
        GreetingCache.stop()
        showIdleGrid()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        intakeTimer?.invalidate()
        hotkey?.stop()
        if recorder.isRecording { recorder.abandon() }
        // Last, and after everything above has had its say: log writes are
        // asynchronous now, so the lines explaining a shutdown are exactly the
        // ones a process can exit out from under. relaunch.sh stops the old
        // instance on every deploy, which makes this the most-travelled exit in
        // the app.
        Permissions.flushLog()
    }

    // MARK: - Properties relocated from elsewhere in the file (App-lane P7,
    // 24 Aug), so their consuming code could move into its own file --
    // extensions cannot add stored properties, only the primary
    // declaration can, so every stored property in this class lives here
    // regardless of which file its own reader/writer ended up in.

    /// Whether the status item actually made it onto the bar. A dropped item's
    /// button window sits off-screen or nowhere; log only on change so the tick
    /// stays quiet.
    var menuBarWasPresent: Bool?

    /// One probe in flight, newest wins; the pending rows never cross an
    /// isolation boundary — they wait here for the probe's verdict.
    var arrivalProbeGeneration = 0
    var pendingArrival: (rows: [SessionRow], waiting: Int,
                                newlyWaiting: Bool)?

    /// The status-item menu, held here rather than assigned to the item: an
    /// assigned menu intercepts every click, and the primary click's job is the
    /// grid. Right-click pops this up.
    var statusMenu: NSMenu?

    /// The drill's own copy of the last measured rebuild cost — see
    /// `RebuildCost` in `AppDelegate+Menu.swift`, the type this stores.
    var lastRebuildCost = AppDelegate.RebuildCost()

}

import AVFoundation
func AVAuthorizationStatusIsUndetermined() -> Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
}

// Draw the app's icon and exit, before any of the app exists.
//
// A build step rather than a checked-in binary asset: the mark is code, so the
// icon is generated from the same path the menu bar draws, and the two can
// never drift. `scripts/bundle.sh` calls this and hands the .iconset to
// iconutil. Handled here, ahead of NSApplication, because this run is not a
// launch — nothing should register a hotkey or take the single-instance lock
// to write a PNG.
if let flag = CommandLine.arguments.firstIndex(of: "--write-iconset"),
   flag + 1 < CommandLine.arguments.count {
    let directory = CommandLine.arguments[flag + 1]
    do {
        try SiteMark.writeIconset(to: directory)
        print(directory)
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("could not write iconset: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // LSUIElement at runtime too
app.run()
