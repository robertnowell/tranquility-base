import AppKit
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
    private var statusItem: NSStatusItem!
    private var hotkey: HotkeyMonitor!
    private let recorder = Recorder()
    private var store: QueueStore?
    private var coordinator: Coordinator?
    private var permissionTimer: Timer?
    private var intakeTimer: Timer?
    private let onboarding = OnboardingWindow()
    private let hud = StatusHUD()

    private var lastStatusLine = "starting…"
    private var isBusy = false

    /// Tap versus hold on the same chord. A tap plays the next waiting update; a
    /// hold records a reply to whatever last spoke. One gesture, two verbs — which
    /// beats two chords to remember, and the boundary is unambiguous in practice
    /// because nobody holds a key for a third of a second by accident.
    private static let tapThreshold: TimeInterval = 0.35

    /// How long the microphone must have been open before a silence-gated
    /// recording is worth saying anything about (ruled 08 Aug). Not a send
    /// threshold — the gate above it is unchanged, and a real 1.2-second "yes,
    /// do it" still goes. This is purely how long you have to have HELD the key
    /// before "no words" is news rather than noise about a slip of the thumb.
    ///
    /// Two seconds because a deliberate utterance is essentially never shorter,
    /// and every sub-second capture the log has ever gated was an accident.
    private static let notionalUtterance: TimeInterval = 2.0

    /// Past this, a recording that carried NO signal at all stops being a quiet
    /// room and starts being a broken input. Five seconds of holding a key is a
    /// deliberate, sustained act; a microphone that produced nothing across it
    /// is not waiting for you to speak up, it is not working.
    private static let deviceFaultHold: TimeInterval = 5.0
    private var pressStartedAt: Date?
    private var listeningIndicator: DispatchWorkItem?
    /// Instant-arm (docs/instant-arm.md): when the arm window opened and the
    /// recorder started capturing optimistically. nil = no optimistic capture
    /// live. Consumed at resolution — cleared by the upgrade (replyBegan) and
    /// by the abort (armAborted), never left set across gestures.
    private var armedAt: Date?
    /// Whether the arming FACE painted (the legality table refuses it over
    /// capture states; audio can arm without pixels).
    private var armedVisually = false
    /// Guards against overlapping announcements. `speech.isSpeaking` is false while
    /// the audio is still being fetched, so two quick taps used to start two
    /// announcements that then talked over each other.
    private var isAnnouncing = false
    /// Set when a reply interrupts playback, so the announce task does not undo the
    /// markHeard that made the reply possible.
    private var repliedToEventId: String?
    /// The one announcement allowed to exist. See `announceNext`.
    private var announceTask: Task<Void, Never>?
    /// The session this recording is addressed to, captured at the moment the
    /// microphone opens and consumed by the send.
    ///
    /// The send used to re-derive its target when the audio arrived — seconds after
    /// you started talking, through fallback chains that could resolve differently
    /// by then. The HTML button replied to the wrong session exactly that way. What
    /// the panel names while you speak and what the send addresses must be the SAME
    /// stored fact, not two derivations that usually agree.
    private var recordingTarget: String?
    /// Sessions this app is mid-delivery to, so the grid can say so. See
    /// `DeliveryInFlight`: the target's own transcript cannot know about a
    /// reply until it lands, so for the whole transcribe → confirm → dispatch
    /// window the row read quiet — the one stretch the user KNOWS is busy,
    /// because they started it. Consumed by `lamp(for:sessionId:)`.
    private var delivering = DeliveryInFlight()
    /// No session to answer? The mic still works: the transcript goes to the
    /// clipboard instead of a terminal. A voice tool that refuses to listen just
    /// because nothing is waiting is leaving its best hardware idle.
    private var dictationMode = false
    /// Hands-free listening: started by a double-tap of ⌥, ended by a single tap.
    /// Distinct from the push-to-talk flag because releasing a key you are not
    /// holding must not end anything.
    private var handsFreeListening = false
    private var lastOptionTapAt: Date?
    /// When hands-free listening last opened, so the twin of a ⌥⌥ cannot close
    /// what the first tap opened. See OptionTapDecision's THE TWIN note.
    private var listeningStartedAt: Date?
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
    private var activeConversation: (sessionId: String, label: String, cwd: String?)?
    /// The most recent announcement, kept whole so ⌃⌃ can speak its depth-1
    /// (goal, risk, question) from the already-computed brief — no model call,
    /// and the session itself is never woken.
    private var lastAnnouncement: Coordinator.Announcement?
    /// Which utterance we have already queued a follow-on render for, so the
    /// eight-per-second highlight tick cannot spawn eight prefetches.
    private var warmedAfter: String?

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
    private func warmNextRung(after index: Int, token: String) {
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
    private var ladderKey: String?
    private var ladderIndex = 0
    /// Ruling 14: an announcement or ⌃⌃ pull that finishes speaking and draws
    /// no gesture within ~4s returns the panel to the idle grid — the card has
    /// said its piece; the grid is the resting face. Cancelled by ANY gesture
    /// (handle()'s first line) and by every new announcement, so mid-speech and
    /// mid-conversation remain chord-driven.
    private var returnToGridWork: DispatchWorkItem?
    private static let returnToGridDelay: TimeInterval = 4
    /// Incremented every time a reply gesture starts.
    ///
    /// Cancelling the countdown only covers the four seconds it is on screen.
    /// Speaking again during transcription — the gap between letting go and the
    /// window appearing — left the earlier reply in flight with nothing watching
    /// it, so it surfaced and sent anyway. A counter covers both windows and any
    /// future one, because it asks "is this still the reply the user wants" rather
    /// than "is a particular UI state showing".
    private var replyGeneration = 0
    /// What the idle grid is currently displaying — row DATA, not counts — so it
    /// is redrawn on content change rather than on every poll. Counts alone
    /// missed real changes: a newer turn replacing an older one leaves the count
    /// identical, and a summary arriving changes a row's topic with no count
    /// change at all.
    private var lastShownRows: [StateLegend.SessionRow]?
    /// The last turn the hail sounded for, as "sessionId:latestId". One hail per
    /// arrival: a tick that re-surfaces the same turn stays quiet — silence after
    /// a hail is "standby", not a request to be hailed again — while a
    /// superseding turn from the same session is a NEW turn and hails anew.
    private var lastHailedTurn: String?
    /// The annunciator's last title, so the count logs on change, not per tick.
    private var lastMenuBarCount: String?
    /// Consulted only for unprompted surfacing. A keypress is never gated: you
    /// cannot interrupt someone who has just asked for something.
    private let gate = InterruptGate(minimumIdleSeconds: 0)
    /// What the gate decided, and what the room sounded like when it decided it.
    /// Not a log-only rollout — the check is live — but the record is where a
    /// surprising hold gets explained after the fact, which is the whole reason
    /// the thresholds can be provisional.
    private let gateLog = GateObservationLog()

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Bind the microphone before anyone can press anything. The first press
        // would otherwise pay for the device bind on the arm path, where ~46ms
        // median (85ms at worst) does not fit the instant-arm grace. Here it is
        // one more thing that happens during launch.
        recorder.warmUp()

        // The recogniser was the one unobservable stage — a fallback transcript
        // quietly missing its first nineteen seconds looked identical to a short
        // reply (PR #1 harvest). app.log therefore contains what you dictated
        // when the Apple floor runs; README discloses this beside model-calls.
        AppleSpeechRecovery.trace = { Permissions.log("apple-speech: \($0)") }

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

                // Write the summary before it is asked for. Doing it on demand meant
                // every use opened with a model call you had to sit through.
                try? await coordinator.prepareNext()

                // Reflect arrivals without being asked. The panel only ever redrew
                // on a keypress, so a session finishing while you were looking
                // straight at it changed nothing and the count went stale. Only
                // while idle: speech, a recording, a countdown or a failure notice
                // are conversations in progress and must not be redrawn under.
                // Housekeeping only — isInFlight gates on the ceiling itself, so
                // an expired entry is already invisible to the lamp. This just
                // stops the map growing across a long-lived app.
                self.delivering.prune()
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
                let arrived = turnArrived && waiting > 0
                if self.hud.canSurfaceAmbiently,
                   arrived || rows != self.lastShownRows {
                    if arrived {
                        self.surfaceArrival(rows: rows, waiting: waiting)
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
        hud.onOpenSettings = { [weak self] in self?.openSettings() }
        // The separate waiting-list face is gone: the idle grid IS the list.
        hud.onPickWaiting = { [weak self] id in self?.announceNext(only: id) }
        hud.onNewSession = { [weak self] in self?.newSession() }
        hud.onNewSessionForArtifact = { [weak self] ref in
            self?.newSession(forArtifact: ref)
        }
        // The card's second door, and the other direction of the same
        // correlation the footer opens: the page links back to its agent, and
        // the agent's card opens its page.
        hud.artifactForSession = { session in
            ArtifactStore.latest(for: session, root: QueueStore.supportDirectory.path)
        }
        hud.onOpenPage = { page in
            NSWorkspace.shared.open(URL(fileURLWithPath: page))
        }
        hud.onBreadcrumbHome = { [weak self] in self?.goHomeFromCard(via: "breadcrumb") }
        hud.onClearLamp = { [weak self] id in
            guard let self, let coordinator = self.coordinator else { return }
            // "Mischief managed" (ruled 06 Aug): the lamp click means "I don't
            // care about this one" — heard, not announced, not invited. Same
            // cursor write a played announcement lands on, so nothing new to
            // reconcile.
            if let target = try? coordinator.waiting().first(where: { $0.sessionId == id }) {
                try? coordinator.markHeard(sessionId: id, through: target.latestId)
                Permissions.log("lamp: cleared \(target.callsign ?? id.prefix(8).description) by click")
            }
            self.showIdleGrid()
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
                guard let chain = self.coordinator?.speech else { return }
                _ = await chain.speak(
                    SpokenTextSanitizer().sanitize(self.previewText()), voice: id)
            }
        }

        hud.onToggleVoice = { [weak self] id, nowOn in
            guard let self else { return }
            var roster = VoiceRoster.load().filter { $0 != id }
            if nowOn { roster.append(id) }
            VoiceRoster.save(roster)
            self.hud.updateSettings(roster: roster)
            Permissions.log("roster: \(nowOn ? "added" : "dropped") \(id) "
                            + "(\(roster.count) on roster)")
        }

        hud.onRosterReordered = { ids in
            VoiceRoster.save(ids)
            Permissions.log("roster: reordered to \(ids.count) entries")
        }

        hud.onDismiss = { [weak self] in
            guard let self else { return }
            self.coordinator?.speech.stop()
            GreetingCache.stop()
            self.isAnnouncing = false
            if self.recorder.isRecording { _ = try? self.recorder.stop() }
            self.handsFreeListening = false
            self.recordingTarget = nil
            self.dictationMode = false
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
        PrivateStorage.harden(directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceDispatch"))

        ElevenLabsSpeechProvider.trace = { Permissions.log("11labs: \($0)") }
        // Populate the picker from the account rather than a hardcoded list.
        Task { @MainActor in
            _ = await VoiceCatalog.refresh()
            self.rebuildMenu()
        }
        Coordinator.trace = { Permissions.log("routing: \($0)") }
        ClaudeAgentsCLI.trace = { Permissions.log("liveness: \($0)") }
        SessionLauncher.trace = { Permissions.log("launcher: \($0)") }
        Secrets.trace = { Permissions.log("secrets: \($0)") }
        QueueStore.trace = { Permissions.log("queue: \($0)") }
        Permissions.log("args=\(CommandLine.arguments)")

        if CommandLine.arguments.contains("--show-onboarding") {
            onboarding.show { }
        }
        if CommandLine.arguments.contains("--selftest-hud") {
            hud.selfTest()
            hud.selfTestPendingSend()
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

        startPermissionPolling()
        refresh()

        // Ask for the microphone at LAUNCH, not on a button press.
        // Calling requestAccess is what registers the app in the Microphone pane —
        // an app that has never asked is not listed there at all, so waiting for a
        // click left the user staring at a list this app could never appear in.
        Permissions.logEnvironment()
        Task { @MainActor in
            let granted = await Permissions.request(.microphone)
            Permissions.log("requestAccess(.audio) returned \(granted); status now \(Permissions.statusDescription(.microphone))")
            refresh()
            announceLaunch()
            // Visible proof of life. A menu-bar-only app with a full menu bar is
            // indistinguishable from a broken one; this makes launch observable.
            showIdleGrid()
        }
    }

    /// Say something on launch.
    ///
    /// A menu-bar-only app gives no other evidence that it started — there is no
    /// window, no dock icon, and the status item is easy to miss. Since the whole
    /// product is a voice, using it to confirm its own liveness is both the cheapest
    /// signal and a real smoke test of the speech path.
    private func announceLaunch() {
        let missing = [micGranted ? nil : "microphone",
                       hotkeyWorking ? nil : "input monitoring"].compactMap { $0 }
        _ = missing  // still logged below; the panel and menu carry the status

        // No spoken greeting. Launch is a state the user caused, watching the
        // screen — the away-channel law at its purest: if it can be communicated
        // visually, it is not spoken. Apps also relaunch mid-work (rebuilds,
        // updates), and announcing yourself each time is noise from the exact
        // product that promised calm. The idle card appearing IS the greeting.
        Task { @MainActor in
            if !Permissions.allGranted {
                onboarding.show { [weak self] in self?.refresh() }
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
    private func goHomeFromCard(via door: String) {
        Permissions.log("\(door): home")
        coordinator?.speech.stop()
        GreetingCache.stop()
        showIdleGrid()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        intakeTimer?.invalidate()
        hotkey?.stop()
        if recorder.isRecording { recorder.abandon() }
    }

    // MARK: - Permissions
    //
    // Polling is how the UI heals itself when the user grants something in System
    // Settings while the menu is open. The hotkey monitor guards against redundant
    // restarts, so calling start() on every tick is safe.

    private func startPermissionPolling() {
        // Ask once, here. See ArrivalChime.requestAuthorization: routing this
        // through onboarding meant it was never asked at all, because a
        // non-blocking permission never makes onboarding appear.
        Task { @MainActor in
            await ArrivalChime.requestAuthorization()
            Permissions.notificationsAuthorized = await ArrivalChime.isAuthorized
            Permissions.log("notifications: \(Permissions.notificationsAuthorized ? "authorized" : "NOT authorized")")
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Dispatch a transcript whose undo window has closed, and say exactly what
    /// happened. "Couldn't send it" hid a `try?` that swallowed the real outcome —
    /// including the one case that matters most, where the text may have landed but
    /// the read-back could not confirm it.
    private func send(utteranceId: String, label: String, sessionId: String) {
        guard let coordinator else { return }
        let mine = replyGeneration
        Task { @MainActor in
            // The second half of the delivery window (see DeliveryInFlight):
            // the capture handed it to the countdown, the countdown handed it
            // here, and it closes on the outcome however that outcome reads.
            // Same discipline as the first half — one defer, not seven cases.
            defer { delivering.finished(sessionId: sessionId) }
            guard mine == replyGeneration else {
                // Superseded between the timer firing and this running.
                try? coordinator.cancelSend(utteranceId: utteranceId)
                return
            }
            // The countdown completing was the confirmation; a "Sending…" card
            // after it is a second wait the user already served. Ready comes back
            // immediately — you can talk again or move on while the dispatch and
            // its read-back verification run behind the scenes. Only repaint if
            // the stage is actually free: on a ⌃⌥ commit-and-advance the next
            // announcement is already preparing, and this must not stomp it.
            lastStatusLine = "sending to \(label)…"
            // The whisper (ruled 06 Aug): the words are on their way, said
            // without taking the stage from whatever is on it.
            hud.showReceipt(.sending(label))
            if hud.canSurfaceAmbiently {
                showIdleGrid()
            }
            do {
                let outcome = try await coordinator.confirmAndSend(utteranceId: utteranceId)
                Permissions.log("confirmAndSend -> \(outcome)")
                // The confirm round-trip can outlive the user's attention: they may
                // already be listening to the NEXT session when this lands. The
                // stage arbiter handles that now — a success receipt asking to
                // paint over live speech or a capture is refused inside
                // showResult, and the REFUSED transition log is its receipt.
                // Failures always surface: they are the case with work left to do.
                switch outcome {
                // Success says nothing: the countdown already confirmed, the
                // status line and log carry the receipt, and a third card for a
                // thing that went right was indistinguishable noise (user report,
                // 05 Aug — "two further states, all saying different things").
                case .queued:
                    hud.showReceipt(.queued)
                    lastStatusLine = "queued in \(label) — sends when its turn finishes"
                    Permissions.log("send: queued in \(label)")
                case .dispatched:
                    hud.showReceipt(.sent)
                    lastStatusLine = "sent to \(label)"
                    Permissions.log("send: confirmed to \(label)")
                case .sessionNotReady(let readiness):
                    // Sanctioned change (b): the actual condition in plain words,
                    // not the enum case's name. Mapping documented in
                    // StateLegend.plainWords(for:).
                    hud.showResult(
                        "\(label) can't take this yet — \(StateLegend.plainWords(for: readiness)). "
                        + "Your words are kept. Try again in a moment.")
                case .dispatchFailed(.verificationTimedOut, _):
                    hud.showResult(
                        "Typed it into \(label), but couldn't confirm it landed. "
                        + "Check the tab before repeating yourself.")
                case .dispatchFailed(.tabNotFound, let utteranceId),
                     .dispatchFailed(.targetGone, let utteranceId):
                    // The destination no longer exists — "kept" must mean usable,
                    // not archived. The words go to the clipboard, plainly said.
                    let copied = copyTranscriptToClipboard(utteranceId: utteranceId)
                    hud.showResult(copied
                        ? "\(label)'s tab is gone — copied your words to the clipboard."
                        : "\(label)'s tab is gone. Your words are kept in the log.")
                case .dispatchFailed(let failure, _):
                    hud.showResult("Couldn't type into \(label): \(failure). "
                                   + "Your words are kept.")
                case .noTarget:
                    hud.showResult("That reply lost its agent. Your words are kept.")
                default:
                    hud.showResult("Unexpected result: \(outcome). Your words are kept.")
                }
            } catch {
                Permissions.log("confirmAndSend threw: \(error)")
                hud.showResult("Send failed: \(error). Your words are kept.")
            }
            rebuildMenu()
        }
    }

    /// Dismiss whatever the panel is showing, through its latest event.
    private func dismissCurrent(_ sessionId: String) {
        guard let coordinator else { return }
        guard let latest = try? coordinator.waiting().first(where: { $0.sessionId == sessionId })
        else { return }
        try? coordinator.dismiss(sessionId: sessionId, through: latest.latestId)
        Permissions.log("dismissed \(sessionId.prefix(8)) through event \(latest.latestId)")
    }

    /// Who the next reply would go to, resolved BEFORE the microphone opens.
    ///
    /// Every mic-opening path runs through this, for two reasons. First, the panel
    /// must name the session and terminal while you talk — addressing you cannot
    /// see is addressing you cannot check, and one misroute already proved it.
    /// Second, if there is no target, the honest move is refusing to record, not
    /// transcribing a reply in order to discover it has nowhere to go.
    private func resolveReplyContext() -> (sessionId: String, pid: Int?, label: String, cwd: String?)? {
        if let conversation = activeConversation {
            // The session on screen or just replied to — your attention, which
            // outranks anything derived from cursors. Its label is already the
            // one identity (callsign-resolved when the announcement painted).
            let live = (ClaudeAgentsCLI().sessions() ?? [])
                .first(where: { $0.sessionId == conversation.sessionId })
            return (conversation.sessionId, live?.pid, conversation.label, conversation.cwd)
        }
        guard let target = try? coordinator?.replyTarget() ?? nil else { return nil }
        let live = (ClaudeAgentsCLI().sessions() ?? [])
            .first(where: { $0.sessionId == target.sessionId })
        // One displayed identity (re-ruled 05 Aug): the tab's string,
        // checkable at a glance — see tabDisplayName.
        let name = tabDisplayName(for: target, live: live)
        return (target.sessionId, live?.pid, name, target.cwd)
    }

    /// The badge, from the same predicate a keypress uses.
    private func waitingNow() -> Int { (try? coordinator?.waitingCount()) ?? 0 }

    /// Whether the status item actually made it onto the bar. A dropped item's
    /// button window sits off-screen or nowhere; log only on change so the tick
    /// stays quiet.
    private var menuBarWasPresent: Bool?
    private func checkMenuBarPresence() {
        let present: Bool = {
            guard let window = statusItem.button?.window else { return false }
            return window.screen != nil && window.frame.minX >= 0
        }()
        if present != menuBarWasPresent {
            menuBarWasPresent = present
            Permissions.log(present
                ? "menubar: item is on the bar"
                : "menubar: item DROPPED for space — bar is full; ⌘-drag it toward the clock once (position autosaves)")
        }
    }

    /// The grid's rows: every LIVE session is a row (ruled, docs/ws-b-ruling.md —
    /// a turn skipped by ⌃⌥ is a visible row, not an absence). Green when the
    /// session is waiting on you; quiet when it is merely alive. Dead sessions
    /// appear nowhere. Identity is the minted callsign with the project label
    /// (or live session name) as fallback until minted.
    private func sessionRowsNow() -> [StateLegend.SessionRow] {
        guard let coordinator else { return [] }
        let waiting = (try? coordinator.waiting()) ?? []
        // One probe serves every row; the name shown is Claude's own (re-ruled
        // 05 Aug — the terminal tab's string, verbatim), callsign as fallback.
        let liveById = Dictionary(
            uniqueKeysWithValues: (ClaudeAgentsCLI().sessions() ?? []).map { ($0.sessionId, $0) })
        // The topic is the stored brief's composed 3–6-word label, carried by
        // the waiting query's brief join — NEVER a prose prefix of summaryText
        // or the raw assistant message (ruled: that derivation produced orphan
        // fragments like "**Voices for lif"). No brief yet = name only.
        var rows = waiting.map {
            StateLegend.SessionRow(
                id: $0.sessionId,
                name: tabDisplayName(for: $0, live: liveById[$0.sessionId]),
                callsign: $0.callsign ?? "",
                // Green says "you have not answered this". While a reply to
                // this very turn is in flight that is the most misleading thing
                // the grid can say — the cursor does not advance until the send
                // confirms, so the row goes on asking for the user seconds after
                // they spoke to it. A newer turn arriving still wins: see
                // DeliveryInFlight.supersedesWaiting.
                lamp: delivering.supersedesWaiting($0.sessionId, latestId: $0.latestId)
                    ? .working : .ready)
        }
        // Live sessions with nothing waiting: quiet rows, so a skipped or heard
        // session stays findable. Walked via `known` — already latestId DESC —
        // so the band is recency-ordered like the waiting band above it, never
        // Dictionary.values hash order (which reshuffled between refreshes).
        // One query for every row's turn edge (see SessionActivity.classify's
        // precedence note): the hooks settle working-vs-idle, which the
        // transcript alone gets wrong 9.8% of the time an agent is working.
        let boundaries = (try? store?.latestTurnBoundaries()) ?? [:]
        let waitingIds = Set(waiting.map(\.sessionId))
        let known = (try? store?.waitingSessionsIncludingHeard()) ?? []
        var placed = waitingIds
        for stored in known where !placed.contains(stored.sessionId) {
            guard let live = liveById[stored.sessionId] else { continue }
            placed.insert(stored.sessionId)
            let activity = stored.transcriptPath.flatMap {
                SessionActivity.read(transcriptPath: $0,
                                     boundary: boundaries[stored.sessionId])
            }
            rows.append(StateLegend.SessionRow(
                id: stored.sessionId,
                name: tabDisplayName(for: stored, live: live),
                callsign: activity?.shortReason ?? (stored.callsign ?? ""),
                lamp: lamp(for: activity, sessionId: stored.sessionId)))
        }
        // Live sessions with no stored events yet: nothing to rank them by,
        // so they close the grid.
        for live in liveById.values where !placed.contains(live.sessionId) {
            let path = live.cwd.map {
                TranscriptTitles.defaultPath(cwd: $0, sessionId: live.sessionId)
            }
            let activity = path.flatMap {
                SessionActivity.read(transcriptPath: $0,
                                     boundary: boundaries[live.sessionId])
            }
            rows.append(StateLegend.SessionRow(
                id: live.sessionId,
                name: StateLegend.displayName(
                    liveName: Self.tabTitle(transcriptPath: nil, live: live),
                    callsign: nil, fallback: "session"),
                callsign: activity?.shortReason ?? "",
                lamp: lamp(for: activity, sessionId: live.sessionId)))
        }
        // Last, and after every band has been appended: a session that is merely
        // alive drops below the ones doing something, without disturbing the
        // recency order the bands above spent this whole function establishing.
        return StateLegend.quietRowsLast(rows)
    }

    /// The lamp a non-waiting session shows. A waiting session is green by
    /// definition (it has something unread for you) and never reaches here;
    /// this answers the question the grid could not: working, stuck, or just
    /// sitting there. Unreadable transcript = the old quiet lamp, never a
    /// guess.
    ///
    /// A delivery in flight upgrades QUIET to blue, and nothing else. That
    /// precedence is the whole rule, and it is deliberate: green and amber are
    /// the two channels that mean *you* — something unread, or something
    /// stopped — and a reply already on its way is news, not a task. Masking
    /// either of them with advisory blue would spend the one signal the grid
    /// exists to carry, to say something the user just did themselves. Quiet
    /// is the only lamp with nothing to lose, and it is exactly the lamp that
    /// was lying.
    private func lamp(for activity: SessionActivity?, sessionId: String) -> StateLegend.Lamp {
        let observed: StateLegend.Lamp = {
            switch activity {
            case .working: return .working
            case .blocked: return .fault
            case .idle, nil: return .running
            }
        }()
        guard observed == .running, delivering.isInFlight(sessionId) else { return observed }
        return .working
    }

    /// The tab's string for a session, or nil while it has none: the
    /// transcript's last ai-title (TranscriptTitles), else the CLI name.
    /// `agents --json`'s name alone is NOT the tab for unnamed sessions —
    /// it is a derived slug ("robertnowell-90") the tab never displays.
    private static func tabTitle(transcriptPath: String?, live: LiveSession?) -> String? {
        let path = transcriptPath ?? live.flatMap { session in
            session.cwd.map {
                TranscriptTitles.defaultPath(cwd: $0, sessionId: session.sessionId)
            }
        }
        let title = path.flatMap { TranscriptTitles.shared.latestTitle(transcriptPath: $0) }
        return title ?? live?.name
    }

    /// EVERY displayed identity for a stored event resolves through here — the
    /// grid rows, the speaking card, the depth-1 why card, the reply target —
    /// so no surface can drift back to the derived slug on its own.
    private func tabDisplayName(for event: WaitingSession, live: LiveSession?) -> String {
        StateLegend.displayName(
            liveName: Self.tabTitle(transcriptPath: event.transcriptPath, live: live),
            callsign: event.callsign, fallback: event.projectLabel)
    }

    /// The one route to the idle face: assemble the grid and show it.
    /// The provenance comes from the compiler, not from each caller remembering
    /// to pass one. Twenty-five call sites reach the grid; asking each to label
    /// itself is twenty-five chances to paste the neighbour's string, which is
    /// how they all ended up saying "idle repaint" in the first place.
    private func showIdleGrid(note: String? = nil,
                              caller: String = #function, line: Int = #line) {
        hud.showIdle(note: note, rows: sessionRowsNow(),
                     because: "grid from \(caller):\(line)")
    }

    /// Arm ruling 14's return: the card has said its piece, it holds for the
    /// delay, and if the panel is still on that card — no gesture moved it —
    /// the grid comes back. Two card states dwell this way: the spoken card
    /// (ruling 14) and the dictation receipt (ui-pass-7, ruling 5). The state
    /// check is the guard: any gesture either cancels this work item outright
    /// or moves the panel off the dwelling state.
    private func scheduleReturnToGrid() {
        returnToGridWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.hud.state {
            case .speaking, .receipt: break
            default: return
            }
            Permissions.log("return-to-grid: card done, "
                + "no gesture for \(Int(Self.returnToGridDelay))s")
            self.showIdleGrid()
        }
        returnToGridWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.returnToGridDelay,
                                      execute: work)
    }

    private func refresh() {
        if !hotkey.isRunning { _ = hotkey.start() }
        rebuildMenu()
        updateTitle()
    }

    private var micGranted: Bool { Recorder.microphoneAuthorized() }
    private var hotkeyWorking: Bool { hotkey?.isRunning ?? false }

    /// An SF Symbol rather than a text glyph.
    ///
    /// The first version used "◌", which is technically visible and practically
    /// invisible: faint, narrow, and indistinguishable from noise in a crowded menu
    /// bar — and on a notched display a narrow new item can end up behind the notch
    /// entirely. A template image renders at the right weight and is findable.
    private func updateTitle() {
        guard let button = statusItem.button else { return }

        // Three states, mapped in the same legend the panel reads from.
        let state: StateLegend.MenuBarState
        if isBusy { state = .busy }
        else if !micGranted || !hotkeyWorking { state = .permissionWarning }
        else { state = .normal }
        let appearance = StateLegend.menuBar(state)

        let image = NSImage(systemSymbolName: appearance.symbol,
                            accessibilityDescription: "Tranquility Base")
        image?.isTemplate = true
        button.image = image
        // The annunciator at rest (WS-B, ruled): the waiting count rides next to
        // the symbol, quiet when nothing is. The liveness-filtered count — the
        // same predicate a keypress uses — so a dead session is never counted.
        let count = StateLegend.menuBarCount(waitingNow())
        button.title = button.image == nil
            // Fall back to text if the symbol is unavailable, rather than nothing.
            ? appearance.textFallback + count
            : count
        button.imagePosition = count.isEmpty ? .imageOnly : .imageLeft
        // Logged on change only, so the annunciator is checkable from the log
        // without a per-tick line.
        if count != lastMenuBarCount {
            lastMenuBarCount = count
            Permissions.log("menubar: count=\(count.isEmpty ? "0 (quiet)" : count)")
        }
        button.toolTip = "Tranquility Base. Click for the grid. Tap ⌃⌥ to hear, hold ⌥ to reply"
    }

    // MARK: - Push to talk

    private func handle(_ transition: HotkeyMonitor.Transition) {
        // Any gesture is attention: the panel must not yank itself back to the
        // grid underneath it (ruling 14's timer dies on contact). The arm
        // window is the one exception — arming is SPECULATION about a hold
        // that may turn out to be a tap or a typing chord, so it must not
        // consume ruling 14's clock; the abort path restarts the clock when
        // its revert lands back on a dwelling card.
        switch transition {
        case .armWindowOpened, .armAborted: break
        default: returnToGridWork?.cancel()
        }
        // Acknowledge before acting — EVERY gesture, no exceptions (ruled
        // 06 Aug: "anytime a chord or command is heard from the user, light up
        // that top bar, and it should be super reliable. I should never
        // question whether my control is having an impact on the system").
        //
        // Unconditional on purpose. The previous version pulsed for three
        // transitions and left the rest to downstream call sites that sat
        // BEHIND their guards, so exactly the presses that did nothing —
        // ⌃⌃ with nothing announced, ⌥ taps outside hands-free, a gesture
        // arriving before the first paint — were the ones that also looked
        // unheard. Acknowledgment is not a reward for a press that worked; it
        // is the receipt for a press that was received.
        switch transition {
        case .armWindowOpened:
            // The light comes on with the key and STAYS on until it lifts
            // (ruled 06 Aug) — one press, one light. Everything the hold
            // becomes downstream (the mic opening, the pill upgrading) must
            // NOT re-light it; that second flash was the stutter.
            hud.holdAcknowledge()
        case .armAborted, .replyEnded, .replyAborted:
            hud.releaseAcknowledge()
        case .replyBegan:
            break  // already lit by the arm that preceded it
        case .next, .dismiss, .optionTapped, .pauseToggled, .controlDoubleTapped:
            hud.acknowledge(.recognized)
        case .controlRegistered:
            // Blue: received, not acted on. The second ⌃ of a ⌃⌃ arrives while
            // this light is still up and recolours it green, so the pair reads
            // as one light resolving rather than two flashes.
            hud.acknowledge(.registered)
        }
        switch transition {
        case .controlRegistered:
            // Acknowledged above and nothing else. A first ⌃ is not an
            // instruction — the whole point of the case is that the light can
            // report a press the app is not going to act on.
            break
        case .next:
            // Open issue #6, wired at last: ⌃⌥ while the microphone is open would
            // start an announcement into a live mic — it would record itself.
            // The question is answered by the state, in one place, for every path
            // that opens the mic through `.listening`.
            guard !hud.isCapturingAudio else {
                Permissions.log("next: ignored, microphone is open")
                return
            }
            // Advancing mid-transcription would announce against a panel the
            // arbiter refuses to repaint; the pendingSend arrives in seconds and
            // the press works then. Same law as the microphone guard above.
            if case .transcribing = hud.state {
                Permissions.log("next: ignored, transcription in flight")
                return
            }
            // During the undo window, ⌃⌥ commits the send and goes HOME
            // (re-ruled 06 Aug, superseding ui-pass-7's commit-and-advance:
            // "it should go to the home screen first" — the readback is not
            // an exception to home-first, and advancing straight into the
            // next agent's voice was the surprise, not the momentum). The
            // countdown fast-forwards, then the grid; a second press invites
            // the next agent from there, same as every other altitude.
            if hud.commitPendingSendNow() {
                Permissions.log("next: committed the pending send, going home")
                showIdleGrid()
                return
            } else if hud.state.isCardOnStage {
                // ⌃⌥ = home first (ui-pass-7, ruling 7). From any card on
                // stage — the announcement or any ⌃⌃ ladder rung, both of
                // which live in `.speaking` — ⌃⌥ stops the voice and returns
                // to the grid, advancing NOTHING: no dismissal, no markHeard,
                // no next announcement. The cursor stays exactly where the
                // announce machinery already put it (Core writes nothing
                // before the audio, so a mid-speech stop leaves the item
                // unread and its row lit; a fully-heard card stays heard).
                // This is also how the ladder cycle (8fecb52) is EXITED: ⌃⌥
                // leaves the walk standing where it is — ⌃⌃ resumes it —
                // rather than advancing it. A rapid double-press composes
                // into "next agent": the first press lands on the grid, and
                // from the grid the second press invites the next agent below.
                goHomeFromCard(via: "⌃⌥")
                return
            }
            // From hidden, ⌃⌥ surfaces the grid and stops (ruled 05 Aug):
            // the queue appears before anyone speaks, so you always see where
            // you are before choosing to listen. The hail is unaffected — a
            // hail has already surfaced the grid, so the go-ahead press finds
            // the panel visible and plays immediately, exactly as before.
            guard hud.isOnScreen else {
                Permissions.log("⌃⌥: surface")
                showIdleGrid()
                return
            }
            // From the visible grid, the empty state, or a receipt/failure
            // card: ⌃⌥ invites the next agent — and this is how a hail's
            // "go ahead" resolves, since the hail surfaces the grid. The old
            // dismiss-on-advance died with home-first: advancing can no
            // longer happen FROM the speaking card at all.
            Permissions.log("⌃⌥: next")
            activeConversation = nil   // moving on is the explicit end of a conversation
            announceNext()

        case .dismiss:
            // Same action as the Dismiss button; a chord because Escape leaks ESC
            // into the focused terminal and interrupts the Claude session there.
            //
            // It is also the recourse out of a transcription (06 Aug: "I cannot
            // cancel transcriptions with a command or anything else"). The
            // cancel button only appears after ~20s of waiting; the chord works
            // from the first second. The audio is already durable on disk, so
            // cancelling costs the transcript, never the recording.
            if case .transcribing = hud.state {
                replyGeneration += 1        // orphans whatever is in flight
                Permissions.log("⌃⇧: cancelled the transcription in flight")
                lastStatusLine = "transcription cancelled — audio kept"
                hud.endCapture(because: "transcription cancelled by chord")
                showIdleGrid(note: "Transcription cancelled. Audio kept.")
                return
            }
            if hud.isBusyOnScreen || hud.isOnScreen { hud.dismiss() }

        case .optionTapped:
            // One tap ends ANY live capture — the mirror of releasing the held
            // key, and the escape hatch from a capture whose release was lost.
            //
            // 06 Aug, from the log: the app sat in `listening` with the mic
            // open and no key held, and every press logged "no meaning in
            // listening" because a tap only meant something in hands-free.
            // A capture with no way out is the trust-killer — "you have to
            // know that when you need to talk, you can talk", and equally
            // that you can stop. Hands-free is now just the case that also
            // clears its latch.
            // The decision is made in Core, where it is tested exhaustively
            // (OptionTapDecisionTests). This handler owns the side effects only.
            // Both of 10 Aug's ⌥ regressions were decisions taken inside an
            // untestable file; the rule "while speaking, ⌥ lets you speak" is now
            // an assertion rather than a sentence in a commit message.
            let decision = OptionTapDecision.decide(
                isSpeaking: hud.state.isSpeaking,
                isRecording: recorder.isRecording,
                isArmed: armedAt != nil,
                withinPairWindow: lastOptionTapAt.map { Date().timeIntervalSince($0) < 0.45 } ?? false,
                listeningJustStarted: listeningStartedAt.map { Date().timeIntervalSince($0) < 0.45 } ?? false,
                micGranted: micGranted)
            Permissions.log("⌥ tap: \(decision) in \(hud.state)")

            switch decision {
            case .ignore:
                return
            case .armFirstOfPair:
                lastOptionTapAt = Date()
                return
            case .endCapture:
                if handsFreeListening { handsFreeListening = false }
                handle(.replyEnded)
                return
            case .startListening:
                break
            }
            // Talking over the announcement is the commonest thing there is, and
            // for a long time it did nothing. Ruled a bug, 10 Aug: "If something
            // is speaking and I hit Option, it should listen to me. It should not
            // be discarded."
            //
            // Until now a tap while speaking only armed the double-tap window, so
            // it took TWO taps inside 0.45s to be heard — and the log of a
            // frustrated session shows exactly what that costs: `⌥ tap: no
            // meaning in speaking` at 19:51:05 and again at 19:51:06, a full
            // second apart, each one forgotten before the next arrived, until the
            // sixth press. A key that ignores you while the app is talking is the
            // one moment you most need it.
            //
            // So while we are speaking, ONE tap is the whole gesture: stop
            // talking and listen. It locks hands-free, which makes the next tap
            // send — the same tap-to-start, tap-to-send pair the double-tap
            // already gave, minus the timing you had to get right.
            do {
                lastOptionTapAt = nil
                guard micGranted else { return }
                if recorder.isRecording {
                    Permissions.log("hands-free: refused, mic already live")
                    lastStatusLine = "mic already live — tap ⌥ to send"
                    return
                }
                // ORDER IS THE WHOLE FIX (10 Aug, second attempt). This block
                // used to mark the session heard and stop the announcement
                // BEFORE opening the microphone. When the open then failed —
                // which the delivery gate now makes visible rather than silent —
                // the session had already gone green-to-empty, the panel had
                // already fallen back to the grid, and there was no recorder to
                // show for it. One tap could lose a waiting agent and give
                // nothing back.
                //
                // Nothing is mutated until the microphone is actually recording.
                // A failed open now leaves the world exactly as it found it: the
                // lamp still green, the announcement still playing, the agent
                // still waiting on you.
                let context = resolveReplyContext()
                do {
                    try recorder.start()
                } catch {
                    Permissions.log("mic: start failed (hands-free) — nothing changed: \(error)")
                    hud.showResult(micFailureMessage(error))
                    return
                }

                handsFreeListening = true
                if let ctx = context {
                    hud.adoptTarget(sessionId: ctx.sessionId, pid: ctx.pid,
                                    label: ctx.label, cwd: ctx.cwd)
                    recordingTarget = ctx.sessionId
                } else {
                    dictationMode = true
                    hud.dictationDestination = FocusedInput.focusedEditableApp()
                        .map { StateLegend.destination($0) } ?? StateLegend.clipboardDestination
                }
                // Deliberately NOT marking the session heard here (ruled 10 Aug).
                // An agent stops waiting when you ANSWER it or when you press its
                // lamp — never because a key was pressed while it happened to be
                // talking. Hearing the first half of an announcement and starting
                // to reply is not the same as being done with it, and the reply
                // path advances the cursor on a confirmed send anyway.
                coordinator?.speech.stop()
                isBusy = true
                listeningStartedAt = Date()
                updateTitle()
                hud.showListening(level: { [weak self] in self?.recorder.level ?? 0 })
                Permissions.log("hands-free: listening locked")
            }

        case .pauseToggled:
            // Handled in the hotkey tap closure (audio-only, ruled); the case
            // exists so the switch stays exhaustive.
            break

        case .controlDoubleTapped:
            // ⌃⌃ = escalate the daemon's channel: speak the rationale and risk
            // for the announcement on stage (or the last one spoken), composed
            // from the brief's already-computed card fields — zero model calls,
            // and the session itself is never woken. Wiring per docs/wiring-a4.md.
            guard let coordinator else { return }
            guard !hud.isCapturingAudio else {
                Permissions.log("depth-1: ignored, microphone is open")
                return
            }
            guard let announcement = lastAnnouncement else {
                // Quiet, not spoken: nothing has been announced this launch, and
                // the voice is the away-channel — it never narrates empty state.
                Permissions.log("depth-1: nothing announced yet; staying quiet")
                return
            }
            // The ladder (ruled: findings → solution → why → message, the
            // order of the stack). Each ⌃⌃ takes the next rung; a new
            // announcement resets the walk. After WHY comes the original
            // MESSAGE re-heard — it lands differently once it has been
            // explained three ways — then the cycle repeats. Empty rungs
            // never made it into the array.
            let key = "\(announcement.event.sessionId):\(announcement.event.latestId)"
            if ladderKey != key { ladderKey = key; ladderIndex = 0 }
            let rungs = SpokenComposition.ladderRungs(for: announcement)
            let rung = rungs[ladderIndex % rungs.count]
            ladderIndex += 1
            let previous = announceTask
            announceTask = Task { @MainActor in
                coordinator.speech.stop()
                previous?.cancel()
                _ = await previous?.value
                guard !Task.isCancelled else { return }
                // Audio ⊂ visual, and the pill NAMES the rung ("◀ FINDINGS") so
                // you always know what kind of thing you are hearing. The live
                // probe resolves the agent's pid exactly as the base
                // announcement does (ui-pass-7, ruling 2): the rung path used
                // to pass nil, which hid "Go to agent" the moment the walk
                // began — the button persists through the entire ladder.
                let live = (ClaudeAgentsCLI().sessions() ?? [])
                    .first { $0.sessionId == announcement.event.sessionId }
                hud.showAnnouncement(
                    spoken: rung.spoken,
                    sessionId: announcement.event.sessionId,
                    pid: live?.pid,
                    project: tabDisplayName(for: announcement.event, live: live),
                    cwd: announcement.event.cwd,
                    eventId: announcement.event.sessionId,
                    placard: "\(StateLegend.Glyph.speaking) \(rung.kind.rawValue)")
                Permissions.log("ladder: \(rung.kind.rawValue) "
                                + "(\(ladderIndex)/\(rungs.count)) for "
                                + "\(announcement.event.sessionId.prefix(8))")
                try? store?.recordDogfood(.depthOnePulled,
                                          sessionId: announcement.event.sessionId)
                // In the session's voice (ruled 05 Aug, a559f29): the pull deepens
                // that session's announcement, so it must sound like it.
                // The rung after this one, warmed while this one talks. Walks
                // continue ~75% of the time at every step, and the render hides
                // completely under the rung already playing.
                let nextRung = ladderIndex
                let warmToken = "\(key):rung\(ladderIndex)"
                _ = await coordinator.speech.speak(
                    rung.spoken,
                    voice: coordinator.voiceId(for: announcement.event.sessionId),
                    onWord: { [weak self] range in
                        Task { @MainActor in
                            guard let self else { return }
                            self.hud.highlight(upTo: range.upperBound)
                            self.warmNextRung(after: nextRung, token: warmToken)
                        }
                    })
                hud.highlight(upTo: rung.spoken.text.count)
                lastStatusLine = "\(rung.kind.rawValue.lowercased()) spoken"
                // Ruling 14: the pull said its piece; with no gesture in 4s the
                // grid comes back. Guarded against a superseding gesture — its
                // cancel of THIS task must not be undone by a late schedule.
                if !Task.isCancelled { scheduleReturnToGrid() }
                rebuildMenu()
            }

        case .armWindowOpened(let pressedAt):
            // Instant-arm (docs/instant-arm.md): bare ⌥ survived the grace.
            // Speculative on purpose — a tap or a chord fully unwinds it.
            guard micGranted else { return }
            guard armedAt == nil, !recorder.isRecording else {
                // Hands-free is live (a ⌥ tap will SEND) or a capture is
                // already running: nothing to arm.
                Permissions.log("arm: skipped, mic already live")
                return
            }
            // Visual FIRST (eval E5): between the grace timer firing and this
            // render sit only in-memory stash writes — no probes, no engine.
            // Identity only if already in hand: resolveReplyContext shells out
            // to the liveness probe and stays where it always was, at
            // hold-resolution.
            armedVisually = hud.showArming(target: activeConversation?.label)
            let visibleMs = Int(Date().timeIntervalSince(pressedAt) * 1000)
            // Audio second: optimistic capture, NO StreamedUtterance — the
            // stream (a network session) is created at hold-resolution as
            // always, and openStream() feeds it this backlog.
            do {
                try recorder.start(openingStream: false)
            } catch {
                // Transient route-change territory; the hold, if it resolves,
                // retries through the ordinary path and reports for real.
                Permissions.log("arm: optimistic mic open failed (\(error)); reverting")
                if armedVisually { hud.revertArming(because: "mic failed") }
                armedVisually = false
                return
            }
            armedAt = Date()
            isBusy = true
            updateTitle()
            let faceNote = armedVisually ? "shown" : "refused, audio-only arm"
            Permissions.log("latency: key-down→arming-visible \(visibleMs)ms"
                + " (face \(faceNote));"
                + " mic open +\(Int(Date().timeIntervalSince(pressedAt) * 1000))ms"
                + " after key-down")

        case .armAborted:
            // The press turned out to be a tap or a real shortcut. Unwind
            // everything the arm did: stop and DISCARD the capture — no
            // utterance row, no file write, no transcription — and restore
            // the exact face the panel wore before. Any tap meaning
            // (optionTapped etc.) arrives after this and acts as it always
            // has.
            let armedDuration = armedAt.map { Date().timeIntervalSince($0) }
            armedAt = nil
            let hadFace = armedVisually
            armedVisually = false
            if armedDuration != nil {
                // Same exception-firewalled teardown as every capture stop
                // (eval E4); abandon returns no audio and writes nothing.
                recorder.abandon()
                isBusy = false
                updateTitle()
            }
            if hadFace { hud.revertArming(because: "tap or chord") }
            if let armedDuration {
                Permissions.log("arm: discarded, \(Int(armedDuration * 1000))ms audio")
            }
            // Ruling 14: if the revert landed back on a dwelling card, its
            // clock — which this gesture deliberately never cancelled, but
            // whose work item may have fired into the arming window and
            // consumed itself — restarts.
            switch hud.state {
            case .speaking, .receipt: scheduleReturnToGrid()
            default: break
            }

        case .replyBegan:
            // Latency instrumentation (ruled 05 Aug: measure before rewiring).
            // t0 is the moment the gesture RESOLVED — the ~0.35s tap-vs-hold
            // threshold has already been paid before this line; HotkeyMonitor
            // owns that constant. What we measure here is everything the app
            // adds on top: teardown, mic engine start, first pill paint.
            let gestureResolvedAt = Date()
            func lat(_ stage: String) {
                let ms = Int(Date().timeIntervalSince(gestureResolvedAt) * 1000)
                Permissions.log("latency: \(stage) +\(ms)ms after hold resolved")
            }
            guard micGranted else { return }
            // Instant-arm: the mic may already be OURS, opened at the arm
            // window. Consume the arm — from here on this is an ordinary
            // reply that simply started capturing ~270ms early.
            let armed = armedAt
            armedAt = nil
            armedVisually = false
            if recorder.isRecording, armed == nil {
                // Refusing silently is how "app seems dead" reports start — the
                // stomped-pill incident left the recorder live behind an idle
                // facade and every press landed here, invisibly.
                Permissions.log("reply: refused, mic already live")
                lastStatusLine = "mic already live — tap ⌥ to send"
                return
            }
            // Open issue #7 is NOT wired here, deliberately. `canStartReply` as a
            // hard refusal would break three live behaviors: dictation-to-clipboard
            // when nothing is waiting (which is how #7's "transcribe then fail" was
            // actually fixed), replying from an idle/hidden panel inside the 15-min
            // reply window, and re-recording during transcription (replyGeneration
            // exists for exactly that). The predicate needs a rethink before it can
            // gate anything. See docs/ws-c-changes.md.
            if let ctx = resolveReplyContext() {
                hud.adoptTarget(sessionId: ctx.sessionId, pid: ctx.pid,
                                label: ctx.label, cwd: ctx.cwd)
                recordingTarget = ctx.sessionId
            } else {
                dictationMode = true
                hud.dictationDestination = FocusedInput.focusedEditableApp()
                    .map { StateLegend.destination($0) } ?? StateLegend.clipboardDestination   // nothing to answer → transcript to clipboard
            }
            // Anything already in flight belongs to a reply you have just replaced.
            replyGeneration += 1
            // Holding ⌥ during the send window means "no, let me say that again".
            // The old transcript is discarded rather than deleted, and the gesture
            // itself starts the new recording, so nothing restarts it twice.
            hud.cancelPendingSend(restartListening: false)
            // NOT marked heard here (ruled 10 Aug). Starting to record is not
            // answering: an agent stops waiting when a reply actually lands, or
            // when you press its lamp — never because you pressed the mic key
            // while it was talking. This used to mark heard first, which meant a
            // press that opened no microphone still took the session out of the
            // queue: green to empty, and the work gone from view with nothing to
            // show for it.
            //
            // The revert this used to defend against is now the correct outcome.
            // Stopping an announcement returns it to unread — which is exactly
            // what it should be, because you have not answered it yet. The reply
            // path advances the cursor on a confirmed send, so a delivered answer
            // still retires it.
            coordinator?.speech.stop()  // never record over playback
            lat("teardown done, opening mic")
            if armed != nil, recorder.isRecording {
                // The mic has been open since the arm window (eval E6: the
                // arm-window audio is already in the durable buffer, so
                // nothing said since the press can be lost). Attach the live
                // stream now — hold-resolution, exactly where it was created
                // before instant-arm — and it is fed the whole backlog.
                recorder.openStream()
                lat("stream opened over armed mic — "
                    + "\(Int(recorder.bufferedSeconds * 1000))ms already buffered, "
                    + "zero-loss window")
            } else {
                do {
                    try recorder.start()
                    lat("mic open")
                } catch {
                    // Route changes make this genuinely transient — say so and stop,
                    // rather than showing a Listening pill over a dead microphone.
                    Permissions.log("mic: start failed: \(error)")
                    dictationMode = false
                    recordingTarget = nil
                    hud.showResult(micFailureMessage(error))
                    return
                }
            }
            isBusy = true
            updateTitle()
            hud.showListening(level: { [weak self] in self?.recorder.level ?? 0 })
            lat("pill rendered")

        case .replyEnded:
            isBusy = false
            hud.recordingEnded()
            guard let captured = try? recorder.stop() else {
                updateTitle()
                // The silence gate's event, one layer down: the device returned
                // so little that Recorder refused to hand it back. This printed
                // "Nothing recorded." over the grid whether you brushed the key
                // or held it for a minute against a dead microphone — the two
                // cases that most need telling apart, and the dead-mic one is
                // the reason this path exists at all.
                reportNothingHeard(because: "nothing recorded")
                return
            }
            updateTitle()
            sendReply(captured)

        case .replyAborted where handsFreeListening:
            // A stray key during locked listening is not an abort signal: nothing is
            // being held, so there is no gesture to have interfered with. Ignore.
            return

        case .replyAborted:
            // The hold turned out to be part of a real shortcut. Drop the audio
            // rather than transcribing whatever happened to be in the room.
            isBusy = false
            hud.recordingEnded()
            recorder.abandon()
            recordingTarget = nil
            dictationMode = false
            updateTitle()
            hud.endCapture(because: "reply aborted")
            showIdleGrid()
        }
    }

    /// Tap: play the next waiting update, then that session becomes the reply target.
    /// Announcements are strictly serialized: at most one exists at any moment, and
    /// a new one cannot begin until the previous one has fully finished.
    ///
    /// A boolean guard was not enough, and could not have been. Pressing again
    /// during the slow part cleared the flag and started a second announcement while
    /// the first was still in flight — so the flag said "one at a time" while two
    /// were running, and both eventually spoke. Two voices talking over each other
    /// is the single worst thing this app can do, so the guarantee has to be
    /// structural: hold the task, cancel it, and AWAIT it before starting anything.
    /// Nothing about timing or ordering is then left to chance.
    private func announceNext(only eventId: String? = nil) {
        guard let coordinator else { return }
        // A new announcement supersedes any armed return-to-grid: the old
        // card's timer must never yank the fresh one off the stage.
        returnToGridWork?.cancel()
        let previous = announceTask
        // Summarizing and fetching the voice take several seconds. Without this the
        // app shows nothing at all for the whole of that and reads as broken.
        // A refusal means a reply flow owns the stage — and the voice obeys the
        // same table as the pixels, so nothing is announced either.
        guard hud.showPreparing() else {
            Permissions.log("announce: refused, reply flow on stage")
            return
        }
        announceTask = Task { @MainActor in
            // Silence the old one first, then wait for it to actually be over.
            coordinator.speech.stop()
            previous?.cancel()
            _ = await previous?.value

            defer { isAnnouncing = false }
            guard !Task.isCancelled else {
                Permissions.log("announce: cancelled before starting")
                return
            }
            isAnnouncing = true

            // Ingest the spool BEFORE selecting. Intake ran only on the 5-second
            // tick, and a human is faster than that: reply to a session, press to
            // hear the next thing, and the reply's user_prompt_submit was still
            // sitting in the spool — so the turn you had just answered played as if
            // nothing had happened. Measured: Stop at 08:38:09, spoken at 08:41:06,
            // the retiring reply landing the same second, five seconds too late.
            _ = try? coordinator.intake()

            // The emptiness check runs HERE, after Preparing has painted, with the
            // probe warmed off-main. It used to run before anything was shown, so a
            // press sat on a frozen panel for the length of a subprocess call and a
            // registered press looked exactly like a missed one.
            await Task.detached { _ = ClaudeAgentsCLI().sessions() }.value
            if eventId == nil, (try? coordinator.nextToAnnounce()) == nil {
                showIdleGrid()
                return
            }
            Permissions.log("announce: starting")
            do {
                // A tap is an explicit request to hear something, so the
                // interruptibility gate does not apply — you cannot interrupt
                // someone who just asked.
                let outcome = try await coordinator.announceNext(
                    only: eventId,
                    ignoringGate: true,
                    onWillSpeak: { [weak self] announcement in
                        // Render BEFORE the audio starts. Showing it afterwards is
                        // useless — you have already heard the whole thing by then.
                        guard let self else { return false }
                        let live = (ClaudeAgentsCLI().sessions() ?? [])
                            .first { $0.sessionId == announcement.event.sessionId }
                        // One displayed identity (re-ruled 05 Aug): the terminal
                        // tab's own string; the voice still speaks the callsign.
                        let name = self.tabDisplayName(for: announcement.event, live: live)
                        // The stage is claimed FIRST. Everything below records
                        // "this is the conversation you are in", and a refused
                        // announcement is not one — recording it anyway is how a
                        // turn nobody heard became the reply target.
                        guard self.hud.showAnnouncement(
                                    spoken: announcement.spoken,
                            sessionId: announcement.event.sessionId,
                            pid: live?.pid,
                            project: name,
                            cwd: announcement.event.cwd,
                            eventId: announcement.event.sessionId)
                        else {
                            Permissions.log("announce: stage refused, not speaking")
                            return false
                        }
                        self.activeConversation = (
                            announcement.event.sessionId,
                            name,
                            announcement.event.cwd)
                        self.lastAnnouncement = announcement
                        return true
                    },
                    onWord: { [weak self] range in
                        Task { @MainActor in
                            guard let self else { return }
                            self.hud.highlight(upTo: range.upperBound)
                            // First audio of the announcement is the moment the
                            // ladder becomes likely — and the moment the main
                            // fetch is provably done, so the two never compete
                            // for a narrow link. Rung 0 is FINDINGS, which is
                            // where essentially every walk opens.
                            guard let last = self.lastAnnouncement else { return }
                            self.warmNextRung(
                                after: 0,
                                token: "\(last.event.sessionId):\(last.event.latestId):main")
                        }
                    }
                )

                // A superseded announcement does not get to speak for the app.
                //
                // Everything below is REPORTING — a status line, a card, the grid.
                // None of it is bookkeeping: the cursor advance and the unread
                // revert both happen inside Coordinator.speak, before this returns.
                // So an announcement that has already been replaced has nothing it
                // needs to do here, and no right to do it — the stage belongs to
                // whatever replaced it.
                //
                // This rule already existed, applied at two of the five places that
                // needed it. The three that lacked it painted the grid over the
                // announcement that superseded them: 38 times in one day, twice
                // while the microphone was open (app.log, `speaking -> idle
                // (grid from announceNext(only:):1378)`). Stated once, above the
                // switch, no branch can be added that forgets it.
                guard !Task.isCancelled else {
                    Permissions.log("announce: superseded, not reporting")
                    return
                }

                switch outcome {
                case .spoke(let announcement):
                    Permissions.log("announce: spoke via \(announcement.via)")
                    if let degraded = announcement.degraded {
                        // Heard, but in the plainer voice. Say why, or an outage
                        // reads as the app just sounding worse for no reason.
                        hud.note("Read in the system voice. \(degraded)")
                    }
                    lastStatusLine = "\(StateLegend.Glyph.speaking) \(announcement.brief.topic)"
                    hud.highlight(upTo: announcement.spoken.text.count)
                    // The agent's page catches up here, off the main thread and
                    // after the audio: the brief for this turn has just been
                    // stored, so this is the first moment the page can be
                    // right, and nothing downstream waits on it. A failure is
                    // logged and dropped — a stale home base must never cost
                    // anyone an announcement.
                    let spokenSession = announcement.event.sessionId
                    Task.detached { [weak self] in
                        guard let store = await self?.store else { return }
                        do {
                            if let file = try HomeBase.write(sessionId: spokenSession,
                                                             store: store) {
                                Permissions.log("homebase: \(file.lastPathComponent) "
                                                + "for \(spokenSession.prefix(8))")
                            }
                        } catch {
                            Permissions.log("homebase FAILED: \(error)")
                        }
                    }
                    // Ruling 14: fully spoken, no gesture in 4s → the grid.
                    scheduleReturnToGrid()
                case .interrupted(let failure):
                    // The announce task reverts an interrupted item to unread. If the
                    // interruption WAS the reply, re-apply the mark — this runs after
                    // the revert, so ordering is settled rather than raced.
                    if let failure {
                        // Nobody asked for this one. Say so, rather than letting a
                        // dropped connection masquerade as something you chose.
                        lastStatusLine = "playback failed, still unread"
                        hud.showResult(
                            "Playback failed (\(failure)). It's still waiting. "
                            + "tap ⌃⌥ to hear it again.")
                    } else {
                        lastStatusLine = "stopped, still unread"
                        showIdleGrid(note: "Stopped, still unread.")
                    }
                case .held(let reason):
                    lastStatusLine = "held: \(reason)"
                    showIdleGrid(note: "Holding. \(reason).")
                case .nothingWaiting:
                    Permissions.log("announce: nothingWaiting")
                    lastStatusLine = "nothing waiting"
                    showIdleGrid()
                }
            } catch {
                Permissions.log("announce: threw \(error)")
                lastStatusLine = "announce failed: \(error)"
            }
            rebuildMenu()
        }
    }

    /// Hold: transcribe and route the reply back to whichever session last spoke.
    // MARK: - Deep links

    /// tranquilitybase://discuss?session=ID&ref=PATH   open that agent
    /// tranquilitybase://hear?session=ID               speak that session's summary
    /// tranquilitybase://reply?session=ID              open the mic, route the reply there
    /// tranquilitybase://show                          raise the panel
    ///
    /// `discuss` is the one a generated page links to, and it is deliberately
    /// the calmest of the four: it puts you in front of the agent — panel up,
    /// its card, its last summary spoken — and stops there. Opening a
    /// microphone because someone clicked a link in a document would be the app
    /// deciding you had something to say; the card already carries the reply
    /// and the tab for when you do.
    ///
    /// This is what lets a local HTML page carry live buttons: an <a href> to a
    /// custom scheme needs no server and no CORS, and the browser confirms before
    /// launching the app, which is the guard against drive-by pages. A reply link
    /// only ever OPENS the microphone with the panel visibly listening — nothing
    /// records silently, and nothing sends without the usual undo window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            // Parsing lives in Core, where it is tested. This layer only acts.
            let parsed = DeepLink.parse(url)
            let action = url.host ?? ""
            let session: String?
            let ref: String?
            switch parsed {
            case let .discuss(s, r): session = s; ref = r
            case let .home(s, r):    session = s; ref = r
            case let .hear(s):       session = s; ref = nil
            case let .reply(s):      session = s; ref = nil
            case .show, .unknown:    session = nil; ref = nil
            }
            Permissions.log("deeplink: \(action) session=\(session?.prefix(8) ?? "-")")
            // A deeplink is an instruction that arrived and is being carried
            // out, so it reads as recognized — the same green a gesture gets.
            hud.acknowledge(.recognized)

            switch action {
            case "discuss":
                discuss(session: session, ref: ref)
            case "hear":
                announceNext(only: session)
            case "reply":
                // Silence here is the failure that reads as a broken link: the
                // browser hands off, the app comes forward, and nothing happens.
                // A refusal that costs a whole click has to say its name.
                guard micGranted else {
                    hud.showResult("The microphone isn't granted, so there is "
                                   + "nothing to reply with. Settings ▸ Privacy "
                                   + "▸ Microphone.")
                    break
                }
                guard !recorder.isRecording else { break }
                // Sweep the spool BEFORE looking, for the reason the announce
                // path does it (main.swift, `announceNext`): hooks append to a
                // text file and the app files it into SQLite on a five-second
                // tick, so a page written seconds ago names a session that is
                // in the queue and not yet in the table. Looking without
                // sweeping reports it missing, which is a lie with a five-second
                // half-life — the worst kind to debug.
                _ = try? coordinator?.intake()
                // The page names its session; that is the whole point of the button.
                // Unknown id → refuse to open the mic, never fall back to a guess.
                guard let session,
                      let target = try? store?.waitingSessionsIncludingHeard()
                          .first(where: { $0.sessionId == session }) else {
                    hud.showResult("That page's agent isn't in the log. Nothing recorded.")
                    break
                }
                let live = (ClaudeAgentsCLI().sessions() ?? [])
                    .first(where: { $0.sessionId == session })
                let pid = live?.pid
                let name = tabDisplayName(for: target, live: live)
                hud.adoptTarget(sessionId: session, pid: pid,
                                label: name, cwd: target.cwd)
                recordingTarget = session
                activeConversation = (session, name, target.cwd)
                // Hands-free, because no key is held: a single ⌥ tap or the Send
                // button ends it. Without this the recording had no clean ending.
                handsFreeListening = true
                coordinator?.speech.stop()
                try? recorder.start()
                isBusy = true
                updateTitle()
                hud.showListening(level: { [weak self] in self?.recorder.level ?? 0 })
            case "home":
                // The agent's own page. Written after every turn, so it exists
                // for any session that has ever been summarized; for one that
                // has not, there is nothing to show and the invitation is the
                // honest answer.
                if let session, let store,
                   let file = try? HomeBase.write(sessionId: session, store: store) {
                    NSWorkspace.shared.open(file)
                } else {
                    inviteNewSession(for: ref)
                }
            case "show":
                showPanel()
            default:
                Permissions.log("deeplink: unknown action \(action)")
            }
        }
    }

    /// "Discuss with agent", from a page that agent wrote.
    ///
    /// Two outcomes and no third: either the agent is here, in which case you
    /// land on it exactly as if you had clicked its row in the grid, or it is
    /// not, in which case you are offered one. The second is not an error path
    /// — it is what EVERY page does eventually, and what every page does
    /// immediately on a machine that is not the one that made it.
    private func discuss(session: String?, ref: String?) {
        // Sweep first, for the same reason `reply` now does: a page can be
        // clicked before its own session has been filed.
        _ = try? coordinator?.intake()
        let known = session.flatMap { id in try? store?.latestStop(for: id) } ?? nil
        guard let session, known != nil else {
            Permissions.log("deeplink: discuss, no agent for \(session?.prefix(8) ?? "-")")
            inviteNewSession(for: ref)
            return
        }
        // The grid row's own move: raise the panel, then read that session's
        // last summary onto the stage. `announceNext(only:)` is deliberately
        // outside the unheard filter, so this answers however many times you
        // click it.
        showPanel()
        announceNext(only: session)
    }

    /// The invitation. Without a `ref` there is nothing to open with and
    /// nothing to say about it, so this stays silent rather than offering a
    /// blank session — the grid's own NEW AGENT row is the door for that.
    private func inviteNewSession(for ref: String?) {
        // A page can put any string in a URL; it cannot put a file on your
        // disk. Everything the invitation goes on to build — a directory, a
        // prompt, a shell command — is derived from a path that got past this,
        // which is why the check lives in Core with tests around it.
        guard let subject = DeepLink.subject(
            from: ref, exists: { FileManager.default.fileExists(atPath: $0) })
        else {
            Permissions.log("invitation: refused ref \(ref ?? "-")")
            hud.showResult("That page names an agent this Mac has no record of, "
                           + "and nothing this Mac can open instead.")
            return
        }
        hud.showNewSessionInvitation(
            artifact: subject.name,
            directory: abbreviatingHome(subject.directory),
            ref: subject.reference)
    }

    /// `~` back, for display only: an absolute home path eats the width the
    /// artifact's own name needs, and the grid abbreviates the same way.
    private func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The one answer to every way a recording can come back with no words in
    /// it — the silence gate below, and the `nothingRecorded` throw in
    /// `.replyEnded`, which is the same event seen one layer down and used to be
    /// answered completely differently ("Nothing recorded." over the grid, or a
    /// failure card, depending on which threshold you happened to trip).
    ///
    /// Three tiers, and the axis is how long the microphone was OPEN — never how
    /// much audio came back. `Recorder.lastOpenSeconds` says why: a dead device
    /// reports a zero-length recording however long you held the key, so buffer
    /// length cannot tell a slip of the thumb from broken hardware.
    ///
    ///   under 2s           nothing at all. You tapped the key or changed your
    ///                      mind. You did not make an error, and a screen that
    ///                      appears for a slip teaches you to fear the key.
    ///   2s+, some signal   one amber line in the grid's strip, on its own
    ///                      clock. You meant to speak, the room was quiet, and
    ///                      saying it again fixes it — so nothing to dismiss.
    ///   5s+, NO signal     a card. The one tier saying it again will not fix:
    ///                      the input is dead, the fix is a setting, so it holds
    ///                      the stage and offers the door out.
    private func reportNothingHeard(because reason: String) {
        let held = recorder.lastOpenSeconds
        let signal = recorder.peakLevel > 0
        Permissions.log(String(format: "nothing heard (%@): held %.2fs, peak %.4f",
                               reason, held, recorder.peakLevel))
        // Home first, through the user door: the capture state owns the stage,
        // so a plain idle repaint is (correctly) refused from it.
        hud.endCapture(because: reason)
        if held >= Self.deviceFaultHold, !signal {
            let device = AudioInputDevice.resolve()
            lastStatusLine = "\(StateLegend.Glyph.needsYou) no audio from "
                + (device?.name ?? "the input device")
            hud.showDeviceFault(StateLegend.noAudioMessage(device: device))
        } else {
            lastStatusLine = "nothing heard"
            showIdleGrid()
            if held >= Self.notionalUtterance {
                hud.flashNotice(StateLegend.noWordsNotice)
            }
        }
        rebuildMenu()
    }

    private func sendReply(_ pcm: Data) {
        guard let coordinator else { return }
        // This utterance's live stream, if one opened. finish() is nil on any
        // stream trouble, and the file path below recovers exactly as before.
        let liveStream = recorder.takeStream()
        // Silence gate. Whisper transcribes near-empty audio into training-data
        // boilerplate — a 765ms accidental capture became "MBC 뉴스 이덕영입니다."
        // and was SENT. A recording that is too short or never rose above the
        // noise floor is refused before any model touches it: hallucinated words
        // in a real terminal are worse than asking you to speak again.
        let seconds = Double(pcm.count) / 2.0 / 16_000.0
        if seconds < 0.5 || recorder.peakLevel < 0.005 {
            Permissions.log(String(format:
                "send: refused, silence gate (%.2fs, peak %.4f)", seconds, recorder.peakLevel))
            recordingTarget = nil
            reportNothingHeard(because: "silence gate")
            return
        }
        let mine = replyGeneration
        lastStatusLine = "transcribing…"
        // Sanctioned change (open issue #4): the transcribing panel shows elapsed
        // seconds, and past 20s offers Cancel and Retry rather than looking hung.
        hud.showTranscribing("Transcribing your reply…",
                             onCancel: { [weak self] in self?.cancelTranscription() },
                             onRetry: { [weak self] in self?.retryTranscriptionFromPanel() })
        rebuildMenu()

        Task { @MainActor in
            do {
                // Address exactly what the panel showed while you spoke — captured
                // at mic-open, consumed here. Re-deriving at send time is how the
                // HTML button's reply reached the wrong session, so a recording
                // with no captured address REFUSES rather than falling back to a
                // derivation: the audio is kept, and nothing is guessed.
                if dictationMode {
                    // Dictation: transcribe, copy, done. No terminal is touched.
                    dictationMode = false
                    hud.showTranscribing("Transcribing…",
                                         onCancel: { [weak self] in self?.cancelTranscription() },
                                         onRetry: { [weak self] in self?.retryTranscriptionFromPanel() })
                    guard let store = self.store else { return }
                    let streamed = await liveStream?.finish()
                    let utterance = try await store.captureAndTranscribe(
                        pcm16: pcm, sampleRate: 16_000, chain: RecoveryChain(), eventId: nil,
                        streamed: streamed, preWritten: self.recorder.lastCaptureURL)
                    // Cancelled (or replaced) while transcribing: the words must not
                    // be pasted anywhere. The audio row is durable and stays.
                    guard mine == replyGeneration else {
                        Permissions.log("dictation: superseded or cancelled mid-transcription; dropped")
                        return
                    }
                    guard let text = utterance.transcriptText, !text.isEmpty else {
                        hud.showResult("Couldn't transcribe that. Audio kept.")
                        return
                    }
                    // Wispr's rule: a focused text field wins; clipboard otherwise.
                    // Dictation success shows its RECEIPT (ui-pass-7, ruling 5
                    // — re-ruled from the blanket Sent-face deletion): the card
                    // tells you where the words went, which nothing else does.
                    // Reply-send success stays silent as ruled. The receipt
                    // dwells, then the grid returns on ruling 14's clock.
                    if let app = FocusedInput.focusedEditableApp() {
                        FocusedInput.paste(text)
                        Permissions.log("dictation: typed \(text.count) chars into \(app)")
                        lastStatusLine = "typed into \(app)"
                        hud.showDictationReceipt("Typed into \(app).")
                    } else {
                        if !FocusedInput.trusted { FocusedInput.requestTrustOnce() }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                        Permissions.log("dictation: copied \(text.count) chars to clipboard")
                        lastStatusLine = "copied to clipboard"
                        hud.showDictationReceipt(
                            "Copied to clipboard: \u{201C}\(text.prefix(80))\u{201D}")
                    }
                    scheduleReturnToGrid()
                    rebuildMenu()
                    return
                }
                guard let spokenTo = recordingTarget else {
                    Permissions.log("send: recording has no captured address; refusing")
                    hud.showResult("This recording lost its address. Audio kept; nothing sent.")
                    rebuildMenu()
                    return
                }
                recordingTarget = nil
                // The delivery window opens HERE — at the capture's close, not
                // at the dispatch — because this is the moment the words become
                // ours to deliver, and every second from here to the outcome is
                // a second the grid used to call that session idle.
                // Which turn this answers, read at the capture's close rather
                // than at dispatch: the whole point is to be right about the
                // row DURING the wait, and a turn that lands while the user is
                // still talking must not be swallowed by their reply to the
                // previous one.
                let answering = (try? coordinator.waiting())?
                    .first { $0.sessionId == spokenTo }?.latestId
                delivering.began(sessionId: spokenTo, answering: answering)
                // One clear-site, not eight. Every exit below closes the window
                // — the supersede return, the six terminal outcomes, the catch —
                // except `.readyToSend`, which hands the delivery to the undo
                // countdown and `send()` to finish. Enumerating exits is how a
                // lamp gets stuck on; a defer keyed to the single hand-off
                // cannot miss one.
                var handedToCountdown = false
                defer { if !handedToCountdown { delivering.finished(sessionId: spokenTo) } }
                let streamed = await liveStream?.finish()
                let outcome = try await coordinator.submitReply(
                    pcm16: pcm, to: spokenTo, streamed: streamed,
                    preWritten: recorder.lastCaptureURL)

                // You started saying it again while this was still transcribing.
                // Drop it rather than offering it: the words you replaced must never
                // reach the session, and they must not queue up behind the new ones.
                if mine != replyGeneration {
                    if case .readyToSend(let staleId, _, _, _) = outcome {
                        try? coordinator.cancelSend(utteranceId: staleId)
                    }
                    lastStatusLine = "replaced by a newer reply"
                    rebuildMenu()
                    return
                }

                switch outcome {
                // Success says nothing on the panel (ruled — the Sent face is
                // dead): status line + log, straight back to the grid.
                case .dispatched(let text, let ms, _):
                    lastStatusLine = "\(StateLegend.Glyph.sent) sent (\(ms)ms): \(text.prefix(48))"
                    hud.endCapture(because: "sent")
                    showIdleGrid()
                case .queued(let text, _):
                    lastStatusLine = "\(StateLegend.Glyph.sent) queued: \(text.prefix(48))"
                    hud.endCapture(because: "queued")
                    showIdleGrid()
                case .noTarget:
                    lastStatusLine = "nothing to reply to yet"
                    hud.showResult("Nothing to reply to yet. Tap ⌃⌥ to hear one first.")
                case .readyToSend(let utteranceId, let text, let coreLabel, let sessionId):
                    // One identity: Core's outcome still carries the project
                    // label; the visual "Sending to X" upgrades it to the minted
                    // callsign when one exists.
                    let label = (try? store?.callsign(for: sessionId)).flatMap { $0 } ?? coreLabel
                    // Sending is the default. The window exists to stop it, not to
                    // permit it: approving every correct transcript is a toll.
                    lastStatusLine = "sending to \(label)…"
                    // The countdown and the send own the window from here.
                    handedToCountdown = true
                    hud.showPendingSend(
                        text: text, label: label, seconds: 4,
                        send: { [weak self] in
                            self?.send(utteranceId: utteranceId, label: label,
                                       sessionId: sessionId)
                        },
                        cancel: { [weak self] restartListening in
                            guard let self else { return }
                            // The recording is kept, just taken out of the sendable
                            // set — you rejected these words, not the audio.
                            try? self.coordinator?.cancelSend(utteranceId: utteranceId)
                            // Nothing is on its way any more: the lamp goes back
                            // to whatever the transcript honestly says.
                            self.delivering.finished(sessionId: sessionId)
                            guard restartListening else { return }
                            // Straight back to listening: you stopped it because the
                            // words were wrong, so the next thing you want is to say
                            // them again, not to hunt for a button.
                            self.hud.showListening(level: { [weak self] in self?.recorder.level ?? 0 })
                            if self.micGranted, !self.recorder.isRecording {
                                try? self.recorder.start()
                                self.isBusy = true
                                self.updateTitle()
                            }
                        })
                case .sessionNotReady(let readiness):
                    // Sanctioned change (b): plain words for the actual condition.
                    let why = StateLegend.plainWords(for: readiness)
                    lastStatusLine = "can't send — \(why); audio kept"
                    hud.showResult("Can't send yet — \(why). Recording kept. Try again shortly.")
                case .transcriptionFailed:
                    lastStatusLine = "couldn't transcribe, audio kept"
                    hud.showResult("Couldn't transcribe that. The audio is saved. Retry from the menu.")
                case .dispatchFailed(.verificationTimedOut, _):
                    lastStatusLine = "\(StateLegend.Glyph.needsYou) unconfirmed. Check the tab before resending"
                    hud.showResult(
                        "Sent, but never confirmed. It may or may not have landed. "
                        + "check the tab before resending.")
                case .dispatchFailed(.tabNotFound, let utteranceId),
                     .dispatchFailed(.targetGone, let utteranceId):
                    // This path painted nothing at all before — a silently lost
                    // reply. Same rescue as the confirm path: clipboard + card.
                    let copied = copyTranscriptToClipboard(utteranceId: utteranceId)
                    lastStatusLine = copied ? "tab gone — words on the clipboard"
                                            : "tab gone — words kept in the log"
                    hud.showResult(copied
                        ? "That tab is gone — copied your words to the clipboard."
                        : "That tab is gone. Your words are kept in the log.")
                case .dispatchFailed(let failure, _):
                    lastStatusLine = "send failed: \(failure), audio kept"
                }
            } catch {
                lastStatusLine = "reply failed: \(error)"
            }
            rebuildMenu()
        }
    }

    /// A reply that cannot be delivered goes to the clipboard — the one place the
    /// user can immediately use it. Deliberately NOT FocusedInput.paste (which
    /// restores the previous clipboard after 0.7s); this is a handoff, not a paste.
    private func copyTranscriptToClipboard(utteranceId: String) -> Bool {
        guard let text = (try? store?.utterances(limit: 500))?
                .first(where: { $0.id == utteranceId })?.transcriptText,
              !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Permissions.log("dispatch rescue: copied \(text.count) chars to clipboard")
        return true
    }

    /// Say what to do, not just that something broke.
    ///
    /// "Try again" is false comfort when the input is Bluetooth: those devices
    /// re-rate themselves the moment the mic opens, so the next press fails
    /// identically, and what the user learns is that the app is unreliable rather
    /// than that the earbuds are. Name the device, name the fix.
    private func micFailureMessage(_ error: Error) -> String {
        if let device = AudioInputDevice.resolve(), device.isBluetooth {
            return "Couldn't open \(device.name). Bluetooth mics change their own "
                + "sample rate when they open — switch to the built-in mic under "
                + "Microphone in the menu bar."
        }
        return "Couldn't open the microphone — try again. (\(error))"
    }

    @objc private func chooseInput(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preference = AudioInputPreference(rawValue: raw) else { return }
        AudioInputPreference.current = preference
        let resolved = AudioInputDevice.resolve(preference)
        lastStatusLine = "mic: \(resolved?.name ?? preference.title)"
        Permissions.log("mic: preference \(preference.rawValue) "
            + "→ \(resolved?.name ?? "engine default")")
        // Rebind now rather than on the next press, for the same reason launch
        // does: the rebuild a preference change forces costs ~46ms, and a gesture
        // is the one place that cannot absorb it. Still the single code path —
        // warmUp defers to rebindEngine, which stays the only thing that decides
        // which device is live.
        recorder.warmUp()
        rebuildMenu()
    }

    @objc private func chooseVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        VoiceCatalog.selectedVoiceId = id
        lastStatusLine = "voice: \(sender.title)"
        rebuildMenu()

        // Hear it now. Choosing from a list of names is guesswork otherwise.
        Task { @MainActor in
            hud.showWorking("Voice set to \(sender.title).")
            self.coordinator?.speech.stop()
            guard let chain = self.coordinator?.speech else { return }
            _ = await chain.speak(SpokenTextSanitizer().sanitize(self.previewText()))
            showIdleGrid()
        }
    }

    /// A turn came back. Decide whether to raise the panel for it.
    ///
    /// Silently, always: showing up IS the signal, and a voice starting on its own
    /// while you are mid-sentence in another session is what gets an app deleted.
    ///
    /// The gate is consulted here for the first time. Until now it only ever vetoed
    /// a keypress, which is backwards — you cannot interrupt someone who just asked
    /// for something. Interrupting is exactly what this does, so this is where a
    /// veto belongs.
    private func surfaceArrival(rows: [StateLegend.SessionRow], waiting: Int) {
        let decision = gate.evaluate()
        guard decision.allowed else {
            // Held, not dropped. The count is still right the moment the panel is
            // next shown, and nothing was lost by staying quiet.
            Permissions.log("ambient: held (\(decision.reason))")
            gateLog.record(decision, context: "arrival")
            // A hail held because the device is busy looks exactly like an agent
            // that never came back, so this one refusal explains itself. Every
            // other veto stays in the log: a locked screen needs no note, and
            // nobody is reading the panel anyway. `flashNotice` paints only in
            // `.idle`, so a dismissed panel is not raised by this — which is the
            // ruling, and is structural rather than remembered.
            return
        }
        let target = try? coordinator?.nextToAnnounce()
        if let front = frontmostSessionTty(), let target,
           let pid = (ClaudeAgentsCLI().sessions() ?? []).first(where: { $0.sessionId == target.sessionId })?.pid,
           ProcessProbe.tty(of: pid) == front {
            // You are looking straight at the tab that just finished. Announcing it
            // is telling you something you can already see — no panel, no hail:
            // showing up is enough, and here you are already there.
            Permissions.log("ambient: skipped, that session is the frontmost tab")
            return
        }
        // RULING 1: an arrival changes what the panel SAYS, never whether it is
        // on screen or how wide it is. A panel you put away stays away.
        //
        // The count in the menu bar is what carries the news to a dismissed
        // panel — refreshed every tick and unable to go stale (WS-B,
        // `menuBarCount`) — plus the chime below, which is the away-channel and
        // does not need a window. Nothing is lost by not summoning one.
        //
        // This is the last unimplemented half of
        // docs/ruling-an-arrival-does-not-move-the-panel.md: `showIdle` raises
        // the panel, and `allowsAmbientSurface` is true for `.hidden`, so every
        // arriving turn re-opened a panel the user had dismissed.
        guard hud.isOnScreen else {
            Permissions.log("ambient: \(waiting) waiting, panel stays dismissed")
            ArrivalChime.play()
            return
        }
        Permissions.log("ambient: surfaced for \(waiting) waiting")
        hud.showIdle(rows: rows)
        // The arrival makes a SOUND, not a sentence.
        //
        // The spoken callsign is dead (ruled 10 Aug). It was the most expensive
        // thing in the app — it needed the interrupt gate, then a courtesy check,
        // then a microphone and a recogniser to decide whether saying one word
        // was rude — and in the whole time it shipped it never once announced
        // successfully. A chime carries the same information ("something came
        // back") at none of that cost, and the panel already carries WHICH.
        ArrivalChime.play()
    }


    /// The tty of the frontmost Terminal tab, or nil if Terminal is not in front.
    private func frontmostSessionTty() -> String? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal"
        else { return nil }
        let script = "tell application \"Terminal\" to return tty of selected tab of front window"
        guard case .success(let out) = AppleScript.run(script: script) else { return nil }
        let tty = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return tty.isEmpty ? nil : tty
    }

    /// The most recent thing it actually said, so a voice is judged on real work.
    private func previewText() -> String {
        let recent = (try? store?.events(limit: 200))?
            .compactMap { $0.summaryText }
            .first(where: { !$0.isEmpty })
        return recent ?? "No sessions have finished yet, so this is what I sound like "
            + "reading nothing in particular."
    }

    private func openSettings() {
        hud.showSettings(
            voices: VoiceCatalog.cached(),
            roster: VoiceRoster.load(),
            note: "Checked voices are the cast; agents draw a durable voice "
                + "in roster order.")
    }

    @objc private func showPanel() {
        showIdleGrid()
    }

    /// Start a fresh Claude session in a new Terminal window (v1 is choiceless:
    /// home directory, `claude --dangerously-skip-permissions`). Its turns
    /// enter the loop — and the grid — as soon as the session first stops.
    private func newSession() {
        newSession(directory: SessionLauncher.defaultDirectory,
                   command: SessionLauncher.defaultCommand)
    }

    /// The invitation's other half: a fresh agent in the artifact's own
    /// directory, opening with the artifact.
    ///
    /// The prompt is handed over twice on purpose. The clipboard copy is
    /// unconditional and cannot fail; the command-line copy is the one that
    /// makes the session start already holding the file, and it is skipped for
    /// any path carrying a quote, because that path would be interpolated
    /// through AppleScript into a shell and both layers quote differently. A
    /// session that opens blank with the prompt one ⌘V away is a small loss; a
    /// mangled `do script` is a window full of shell errors as the first thing
    /// a new user sees.
    private func newSession(forArtifact path: String) {
        // Re-resolved rather than trusted: the card has been on screen for as
        // long as the user took to decide, and the string that reaches the
        // shell should be checked at the moment it is used, not the moment it
        // was displayed.
        guard let subject = DeepLink.subject(
            from: path, exists: { FileManager.default.fileExists(atPath: $0) })
        else {
            hud.showResult("That page's subject is no longer there. Nothing started.")
            return
        }
        let directory = subject.directory
        let opening = DeepLink.openingPrompt(for: subject)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(opening, forType: .string)
        let inline = DeepLink.openingCommand(base: SessionLauncher.defaultCommand,
                                             prompt: opening)
        let command = inline ?? SessionLauncher.defaultCommand
        Permissions.log("invitation: launching in \(directory) "
                        + "(prompt \(inline == nil ? "clipboard only" : "inline"))")
        newSession(directory: directory, command: command)
    }

    private func newSession(directory dir: String, command: String) {
        let before = Set((ClaudeAgentsCLI().sessions() ?? [])
            .filter { $0.cwd == dir }.map(\.sessionId))
        switch SessionLauncher.launch(directory: dir, command: command) {
        case .success:
            lastStatusLine = "new session launched"
            rebuildMenu()
            // First-run reality (ruled, docs/ws-b-ruling.md): the directory-trust
            // prompt is a security consent and is NEVER auto-answered. If no new
            // session registers in the launched cwd within ~30s, say so with a
            // quiet visual note — a walked-away launch must not be a silently
            // stillborn investigation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    let after = await Task.detached { ClaudeAgentsCLI().sessions() }.value
                    let registered = (after ?? []).contains {
                        $0.cwd == dir && !before.contains($0.sessionId)
                    }
                    guard !registered else { return }
                    Permissions.log("launcher: no session registered in \(dir) after 30s")
                    if self.hud.canSurfaceAmbiently {
                        self.showIdleGrid(
                            note: "New agent is waiting on a prompt in Terminal.")
                    }
                }
            }
        case .failure(let error):
            hud.showResult("Couldn't start an agent: \(error.message). "
                           + "Terminal automation permission is the usual suspect.")
        }
    }

    @objc private func newSessionTapped() { newSession() }

    // MARK: - Menu

    /// The status-item menu, held here rather than assigned to the item: an
    /// assigned menu intercepts every click, and the primary click's job is the
    /// grid. Right-click pops this up.
    private var statusMenu: NSMenu?

    /// Left-click opens the grid; right-click opens the menu. The grid is the
    /// interface, the menu is the toolbox.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if hud.isOnScreen {
            // Toggle (ruled 05 Aug): the click that opens the panel also hides
            // it. From the resting grid that is a plain hide — nothing on stage
            // to retire. From any active state it is the full dismiss, because
            // hiding a panel must never strand a live microphone or mark an
            // announcement heard-by-accident: dismiss is the honest teardown.
            if hud.canSurfaceAmbiently { hud.hide() } else { hud.dismiss() }
        } else {
            showPanel()
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled(lastStatusLine))
        menu.addItem(.separator())

        // A guaranteed way back to the panel. The status icon can end up behind the
        // notch or in the overflow on a crowded menu bar, and then there is no
        // discoverable route to a window that has no Dock icon by design.


        // The proactive half (ruled 05 Aug addendum): kick off an investigation
        // instead of reacting to one. Same code path as `tbase new` and the
        // grid's "+" row. Deliberately no gesture binding — a mis-hold that
        // spawns terminals is worse than a click.
        let newSession = NSMenuItem(title: "New session",
                                    action: #selector(newSessionTapped), keyEquivalent: "")
        newSession.target = self
        menu.addItem(newSession)

        // Picking a voice plays it immediately. A name in a list tells you nothing
        // about what it sounds like, and the whole point of choosing is hearing.
        let voices = VoiceCatalog.cached()
        if !voices.isEmpty {
            let item = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let selected = VoiceCatalog.selectedVoiceId
            for group in ["cloned", "generated", "professional", "premade"] {
                let inGroup = voices.filter { $0.category == group }
                guard !inGroup.isEmpty else { continue }
                if submenu.numberOfItems > 0 { submenu.addItem(.separator()) }
                submenu.addItem(disabled(group.capitalized))
                for voice in inGroup.sorted(by: { $0.name < $1.name }) {
                    let entry = NSMenuItem(
                        title: voice.name, action: #selector(chooseVoice(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = voice.id
                    entry.state = voice.id == selected ? .on : .off
                    submenu.addItem(entry)
                }
            }
            item.submenu = submenu
            menu.addItem(item)
        }

        // Microphone, here rather than in the settings pane, for the same reason
        // the voice picker is here: it is a one-click choice, not an editor. The
        // pane is a roster editor with its own drag-ordering face; a two-item
        // radio group does not belong in it.
        //
        // The entries name the resolved DEVICE, not the policy. "System default"
        // tells you nothing about whether you are about to record through the
        // earbuds that will fail — which is why the warning marks auto-detect and
        // not just the Bluetooth entry.
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let preference = AudioInputPreference.current
        for option in AudioInputPreference.allCases {
            let resolved = AudioInputDevice.resolve(option)
            let named = option == .systemDefault
                ? resolved.map { " (\($0.name))" } ?? "" : ""
            let warning = (resolved?.isBluetooth ?? false) ? "  ⚠︎" : ""
            let entry = NSMenuItem(title: option.title + named + warning,
                                   action: #selector(chooseInput(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = option.rawValue
            entry.state = option == preference ? .on : .off
            micMenu.addItem(entry)
        }
        micItem.submenu = micMenu
        menu.addItem(micItem)

        menu.addItem(.separator())

        menu.addItem(disabled("⌃⌥ hear · hold ⌥ reply · ⌥⌥ hands-free · ⇧ pause · ⌃⇧ dismiss"))
        menu.addItem(.separator())

        menu.addItem(permissionRow(
            title: "Microphone", granted: micGranted,
            action: #selector(openMicrophoneSettings)))
        menu.addItem(permissionRow(
            title: "Input Monitoring (hotkey)", granted: hotkeyWorking,
            action: #selector(openInputMonitoringSettings)))
        menu.addItem(.separator())

        // No "N waiting" row here. It read from the unfiltered store count and
        // disagreed with every other surface (dead sessions counted); the count
        // lives in the menu-bar title now, liveness-filtered like everything else.
        let retry = NSMenuItem(title: "Retry failed transcriptions",
                               action: #selector(retryFailed), keyEquivalent: "")
        retry.target = self
        menu.addItem(retry)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusMenu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func permissionRow(title: String, granted: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "\(granted ? StateLegend.Glyph.confirm : StateLegend.Glyph.denied)  \(title)", action: granted ? nil : action,
                              keyEquivalent: "")
        item.target = granted ? nil : self
        item.isEnabled = !granted
        return item
    }

    @objc private func showOnboarding() {
        onboarding.show { [weak self] in self?.refresh() }
    }

    @objc private func openMicrophoneSettings() {
        // macOS never re-prompts after a denial, so past the first ask the only
        // route is System Settings. Deep-link rather than describing where to click.
        Task { @MainActor in
            if AVAuthorizationStatusIsUndetermined() {
                _ = await Recorder.requestMicrophoneAccess()
                refresh()
                return
            }
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    @objc private func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    @objc private func retryFailed() {
        guard let store else { return }
        Task { @MainActor in
            let recovered = (try? await store.retryFailedTranscriptions()) ?? []
            lastStatusLine = recovered.isEmpty
                ? "nothing to recover"
                : "recovered \(recovered.count) utterance(s)"
            rebuildMenu()
        }
    }

    // MARK: - Slow transcription (sanctioned change: open issue #4)

    /// Cancel from the transcribing panel: discard the utterance and return to idle.
    ///
    /// The in-flight network call is not interruptible, so cancellation is the same
    /// mechanism that guards against re-recording: bump the generation, and the
    /// result is dropped (reply path) or its send cancelled (readyToSend) when it
    /// finally lands. The audio row was durable before the network was touched, so
    /// nothing is lost — `tbase utterances` still has it.
    private func cancelTranscription() {
        replyGeneration += 1
        recordingTarget = nil
        dictationMode = false
        lastStatusLine = "transcription cancelled, audio kept"
        Permissions.log("transcription: cancelled from the panel; audio is kept")
        // The user door out of the capture state — without it the arbiter would
        // refuse the idle repaint below and strand the panel.
        hud.endCapture(because: "transcription cancelled")
        showIdleGrid()
        rebuildMenu()
    }

    /// Retry from the transcribing panel: the existing recovery path, exactly the
    /// same as the "Retry failed transcriptions" menu item.
    ///
    /// Honest limitation, stated: the recovery sweep re-runs utterances whose
    /// transcription has FAILED, from their audio on disk. It cannot preempt the
    /// one still in flight — no provider in the chain supports that — so mid-flight
    /// this recovers any earlier failures and otherwise waits the current attempt
    /// out. The panel keeps its elapsed counter either way.
    private func retryTranscriptionFromPanel() {
        Permissions.log("transcription: retry requested from the panel")
        retryFailed()
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Instant-arm selftest (docs/instant-arm.md, evals E2/E4/E5)

    /// Drives the arm window through the REAL handler — real recorder, real
    /// store — and asserts what the unit tests cannot: a tap after arming
    /// leaves zero durable residue (E2: no utterance row, no audio file, no
    /// stream session), the recorder is closed after every abort path (E4),
    /// and the grace-fire→render path stays within the latency budget (E5).
    private func runArmSelftest() {
        guard micGranted else {
            Permissions.log("selftest-arm: SKIPPED — microphone not granted")
            return
        }
        guard let store else {
            Permissions.log("selftest-arm: SKIPPED — no store")
            return
        }
        func utteranceCount() -> Int { (try? store.utterances(limit: 10_000).count) ?? -1 }
        func audioFileCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(
                at: QueueStore.audioDirectory, includingPropertiesForKeys: nil).count) ?? -1
        }
        // Stream sessions are counted, not opened: a nil-returning factory
        // proves WHEN the app asks for a stream without touching the network.
        let originalFactory = recorder.streamFactory
        defer { recorder.streamFactory = originalFactory }
        let streamAsks = Counter()
        recorder.streamFactory = { streamAsks.increment(); return nil }

        let rowsBefore = utteranceCount()
        let filesBefore = audioFileCount()

        // A clean stage first: --selftest-hud's pendingSend drill leaves the
        // panel owning the stage, which would (correctly) refuse both the
        // idle repaint and the arming face and turn this into a test of the
        // wrong thing.
        hud.endCapture(because: "selftest-arm setup")

        // E5: the grace-fire→render path, timed directly. The handler's own
        // ordering (render BEFORE recorder.start) is the review-level half,
        // documented in docs/instant-arm.md.
        showIdleGrid()
        let renderStart = Date()
        hud.showArming(target: "selftest")
        let renderMs = Date().timeIntervalSince(renderStart) * 1000
        hud.revertArming(because: "selftest E5 timing")
        Permissions.log(String(format:
            "selftest-arm E5: grace-fire→render %.1fms (budget 30ms) %@",
            renderMs, renderMs <= 30 ? "PASS" : "FAIL"))

        // E2 + E4, abort from the visible grid: arm, then tap-abort.
        handle(.armWindowOpened(pressedAt: Date()))
        let armedOk = recorder.isRecording && hud.state.name == "arming"
        handle(.armAborted)
        let gridAbort = !recorder.isRecording && streamAsks.value == 0
        Permissions.log("selftest-arm abort[grid]: armed=\(armedOk) "
            + "micClosed=\(!recorder.isRecording) streams=\(streamAsks.value) "
            + "state=\(hud.state.name) \(armedOk && gridAbort ? "PASS" : "FAIL")")

        // Abort from hidden: arming surfaced the panel; the revert re-hides.
        hud.hide()
        handle(.armWindowOpened(pressedAt: Date()))
        let surfaced = hud.isOnScreen && hud.state.name == "arming"
        handle(.armAborted)
        let rehidden = !hud.isOnScreen && hud.state.name == "hidden"
            && !recorder.isRecording
        Permissions.log("selftest-arm abort[hidden]: surfaced=\(surfaced) "
            + "rehidden=\(rehidden) \(surfaced && rehidden ? "PASS" : "FAIL")")

        // E4's other abort leg: arm → hold resolves (upgrade) → replyAborted.
        // The stream ask here is EXPECTED — hold-resolution is where streams
        // have always been created; the abort still leaves no residue. The
        // reply is addressed to a synthetic conversation so the selftest can
        // never markHeard a REAL waiting session (prod-data guard).
        showIdleGrid()
        activeConversation = ("selftest-arm", "selftest-arm", nil)
        defer { activeConversation = nil }
        handle(.armWindowOpened(pressedAt: Date()))
        handle(.replyBegan)
        let upgraded = recorder.isRecording && streamAsks.value == 1
        handle(.replyAborted)
        let replyAbortClean = !recorder.isRecording
        Permissions.log("selftest-arm abort[upgrade]: upgraded=\(upgraded) "
            + "micClosed=\(replyAbortClean) "
            + "\(upgraded && replyAbortClean ? "PASS" : "FAIL")")

        // E2's ledger: nothing durable moved across any of the above.
        let rowsAfter = utteranceCount()
        let filesAfter = audioFileCount()
        let clean = rowsAfter == rowsBefore && filesAfter == filesBefore
        Permissions.log("selftest-arm E2: utteranceRows \(rowsBefore)→\(rowsAfter) "
            + "audioFiles \(filesBefore)→\(filesAfter) "
            + "\(clean ? "PASS" : "FAIL")")
        showIdleGrid()
    }
}

/// A tiny thread-safe counter for the selftest's stream-ask ledger.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

import AVFoundation
private func AVAuthorizationStatusIsUndetermined() -> Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // LSUIElement at runtime too
app.run()
