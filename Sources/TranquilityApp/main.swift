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
    private var statusItem: NSStatusItem!
    private var hotkey: HotkeyMonitor!
    private let recorder = Recorder()
    private var store: QueueStore?
    private var coordinator: Coordinator?
    private var permissionTimer: Timer?
    private var intakeTimer: Timer?
    private let onboarding = OnboardingWindow()
    private let utterancePlayer = UtterancePlayer()
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
    /// Where the ⌃⌥ walk over an all-opened stack has got to. Nil means start
    /// at the top. In memory only, and reset by any fresh or named
    /// announcement — a walk is a gesture in progress, not durable state.
    private var lastReplayed: String?
    /// The session this recording is addressed to, captured at the moment the
    /// microphone opens and consumed by the send.
    ///
    /// The send used to re-derive its target when the audio arrived — seconds after
    /// you started talking, through fallback chains that could resolve differently
    /// by then. The HTML button replied to the wrong session exactly that way. What
    /// the panel names while you speak and what the send addresses must be the SAME
    /// stored fact, not two derivations that usually agree.
    private var recordingTarget: String?

    /// The launch this capture is answering, when the agent has no id yet.
    ///
    /// Set instead of `recordingTarget` when you answer a greeting card before
    /// its session has registered — which is the common case, not the rare one:
    /// registration measured five to nine seconds across every launch in the
    /// 18 Aug log, and the card exists precisely so you can answer immediately.
    private var recordingLaunch: PendingLaunch?

    /// The launch that is still coming up, if any.
    private var pendingLaunch: PendingLaunch?
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
    /// Ruling 14, REVERSED for spoken cards (Robert, 12 Aug): a finished
    /// announcement or ⌃⌃ pull dwells until a gesture moves it — the reader,
    /// not a clock, decides when the card has been read. The original ruling
    /// (8985bbe, 05 Aug: "no gesture within ~4s returns the panel to the
    /// grid") was made three days after the isPaused hang shipped, so on the
    /// ElevenLabs path it was never once experienced until the hang was fixed
    /// on 11 Aug — and the first real exposure reversed it. The dictation
    /// receipt (ui-pass-7, ruling 5) is a different ruling and still
    /// auto-returns: it is a passive confirmation with nothing left to act on.
    private var returnToGridWork: DispatchWorkItem?
    /// Who a dropped file would be staged for, and whose chips the panel is
    /// therefore showing. One value answers both, so what you can see is
    /// always exactly what would ride.
    ///
    /// Cached, and deliberately NOT `resolveReplyContext()`: that probe
    /// shells out for a pid, and this is read on every repaint. Refreshed on
    /// the tick and at every moment that changes the addressee.
    private var dropTarget: (sessionId: String, label: String)?
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
    private var lastWaitingIds: Set<String>?
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

    /// Auditions macOS voices. Long-lived so `stop()` can silence the previous
    /// preview — a per-press instance would leave the old one talking over the new.
    private let voicePreview = SystemSpeechProvider()
    /// What the gate decided, and what the room sounded like when it decided it.
    /// Not a log-only rollout — the check is live — but the record is where a
    /// surprising hold gets explained after the fact, which is the whole reason
    /// the thresholds can be provisional.
    private let gateLog = GateObservationLog()

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
                self.lastStatusLine = "microphone suspended — capture stack wedged, heal scheduled"
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
            if hud.pose(name), let png = hud.poseSnapshot() {
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
                guard let live = (ClaudeAgentsCLI().sessions() ?? [])
                    .first(where: { $0.sessionId == id }) else {
                    Permissions.log("terminate: \(name) (\(id.prefix(8))) not in agents — already gone")
                    await MainActor.run { self?.refreshGridAfterTerminate() }
                    return
                }
                // The tty the session was seen on, handed to the ladder as the
                // second half of its identity guard.
                let outcome = SessionTermination.end(
                    pid: live.pid, named: name,
                    expectedTty: ProcessProbe.tty(of: live.pid))
                switch outcome {
                case .refused(let why):
                    Permissions.log("terminate: \(name) NOT ended — \(why)")
                case .survived:
                    Permissions.log("terminate: \(name) (pid \(live.pid)) survived "
                        + "SIGTERM and SIGKILL — it is wedged, and nothing else can be sent")
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

        hud.onShowRecentAudio = { [weak self] in self?.showRecentAudio() }
        // One door per pane. The panel asks for a tab; the host assembles that
        // tab's data and shows it. Nothing re-renders a pane it has not fed.
        hud.onOpenSettingsTab = { [weak self] tab in
            guard let self else { return }
            switch tab {
            case .agents: hud.showAgentSettings()
            case .voices: openSettings(tab: .voices)
            case .recent: showRecentAudio()
            }
        }

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
        if let problem = HookManifest.problemSummary() {
            // Repair, not just report (Robert, 12 Aug: "nobody ever wants to
            // run a command — we either keep it up to date or give them one
            // click"). The repair is bounded to entries carrying our markers,
            // backs the file up first, and its receipt is a re-audit. When it
            // cannot repair — no healthy entry and no recorded directory to
            // learn from — noticing remains the floor, said out loud, because
            // a hook's own contract (exit 0 whatever happens) means nothing
            // else ever will.
            Permissions.log("startup: \(problem)")
            switch HookManifest.repair() {
            case .healthy:
                Permissions.log("startup: hooks healthy on re-audit")
            case .repaired(let rewired, let added):
                Permissions.log("startup: hooks repaired — "
                    + "\(rewired) rewired, \(added) added")
                hud.note("Hooks were out of date — fixed. "
                    + "New Claude Code sessions pick them up automatically.")
            case .unavailable(let reason):
                Permissions.log("startup: hooks NOT repaired — \(reason)")
                hud.note("Hooks need attention: \(reason)")
            }
        } else {
            Permissions.log("startup: hooks installed and reachable")
        }

        if CommandLine.arguments.contains("--show-onboarding") {
            onboarding.show { }
        }
        if CommandLine.arguments.contains("--selftest-hud") {
            hud.selfTest()
            // Before selfTestPendingSend: that one holds the panel for five more
            // seconds and releases the drill hold when it is done.
            hud.selfTestReadbackDoor()
            hud.selfTestPendingSend()
            // The voice-menu cache drill (issue 14, nested blocker). Three
            // seconds is far past the off-thread loader's worst case, so by
            // now the snapshot must be warm, the menu must carry the Voice
            // submenu, and a rebuild must be quick even with the catalogue
            // populated — the tick never again pays the TTS daemon's price.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                let warm = !SystemVoiceCatalog.cachedRows().catalogue.isEmpty
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
    }

    // MARK: - Permissions
    //
    // Polling is how the UI heals itself when the user grants something in System
    // Settings while the menu is open. The hotkey monitor guards against redundant
    // restarts, so calling start() on every tick is safe.

    /// Live state for the earcon gate. Read on the main actor at the moment a cue
    /// wants to play, never cached: a snapshot is a thing that goes stale, and the
    /// whole point of the gate is that it reflects RIGHT NOW.
    private func earconGate() -> EarconGate {
        EarconGate(
            userIsSpeaking: recorder.isRecording,
            agentIsSpeaking: {
                guard let speech = coordinator?.speech else { return false }
                return speech.isSpeaking || speech.isPaused
            }())
    }

    private func startPermissionPolling() {
        Earcons.clearOldNotifications()
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
            // The undo window closed, which is the moment the user CONFIRMED the
            // send. Ruled 18 Aug: "dispatch means turn done" — so this is the
            // closure cue, and it is the only falling figure in the set.
            Earcons.play(.dispatched, gate: earconGate())
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
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult(
                        "\(label) can't take this yet — \(StateLegend.plainWords(for: readiness)). "
                        + "Your words are kept. Try again in a moment.")
                case .dispatchFailed(.verificationTimedOut, _):
                    // Documented as ambiguous and never auto-retried: only a human
                    // can decide whether to repeat themselves. That is needs-you.
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult(
                        "Typed it into \(label), but couldn't confirm it landed. "
                        + "Check the tab before repeating yourself.")
                case .dispatchFailed(.tabNotFound, let utteranceId),
                     .dispatchFailed(.targetGone, let utteranceId):
                    // The destination no longer exists — "kept" must mean usable,
                    // not archived. The words go to the clipboard, plainly said.
                    Earcons.play(.needsYou, gate: earconGate())
                    let copied = copyTranscriptToClipboard(utteranceId: utteranceId)
                    hud.showResult(copied
                        ? "\(label)'s tab is gone — copied your words to the clipboard."
                        : "\(label)'s tab is gone. Your words are kept in the log.")
                case .dispatchFailed(let failure, _):
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult("Couldn't type into \(label): \(failure). "
                                   + "Your words are kept.")
                case .noTarget:
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult("That reply lost its agent. Your words are kept.")
                default:
                    Earcons.play(.needsYou, gate: earconGate())
                    hud.showResult("Unexpected result: \(outcome). Your words are kept.")
                }
            } catch {
                Permissions.log("confirmAndSend threw: \(error)")
                Earcons.play(.needsYou, gate: earconGate())
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

    /// Recompute who a dropped file would go to.
    ///
    /// The same ladder `resolveReplyContext` walks — the conversation you are
    /// in, else the session that last spoke — minus the pid probe, which is a
    /// subprocess and which a staged file does not need. Deliberately the
    /// same ladder: a file must land where your voice would, or the panel is
    /// naming one destination and using another.
    private func refreshDropTarget() {
        if let conversation = activeConversation {
            dropTarget = (conversation.sessionId, conversation.label)
            return
        }
        guard let target = try? coordinator?.replyTarget() ?? nil else {
            dropTarget = nil
            return
        }
        dropTarget = (target.sessionId, target.callsign ?? target.projectLabel)
    }

    /// A dragged image with no file behind it, written somewhere durable.
    ///
    /// Content-hashed rather than timestamped: dropping the same screenshot
    /// twice is one chip and one file, and a session that reads the path
    /// later finds the bytes it was told about. Beside the audio archive,
    /// under app support — a temp dir would be swept out from under a
    /// session that had not read it yet.
    private static func persistDroppedImage(_ data: Data, ext: String) -> String? {
        let dir = QueueStore.supportDirectory.appendingPathComponent("dropped",
                                                                     isDirectory: true)
        try? PrivateStorage.createDirectory(at: dir)
        let digest = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }
            .joined().prefix(16)
        let url = dir.appendingPathComponent("drop-\(digest).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            Permissions.log("drop: write failed — \(error)")
            return nil
        }
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
        //
        // `uniquingKeysWith:` rather than `uniqueKeysWithValues:`, because the latter
        // TRAPS on a duplicate key and `agents --json` genuinely returns them:
        // `claude --resume <id>` leaves the original process running and adds a second
        // live entry carrying the SAME sessionId. That killed the app twice —
        // 06 Aug 14:35 and 07 Aug 17:39 — the second crash landing eighteen seconds
        // after a resume started. EXC_BREAKPOINT in a refresh timer, so it fires as
        // soon as the duplicate appears and there is no recovery path.
        //
        // First-seen wins, matching the `first(where:)` lookups used on every other
        // path (Coordinator.dispatch among them), so one rule governs everywhere
        // rather than this view resolving collisions differently from dispatch.
        // WHICH duplicate is the right target is a separate, open question — both
        // processes are alive and both answer to the id — so the collision is logged
        // rather than silently settled.
        var liveById: [String: LiveSession] = [:]
        for session in ClaudeAgentsCLI().sessions() ?? [] {
            if let existing = liveById[session.sessionId] {
                Permissions.log("agents: duplicate sessionId \(session.sessionId.prefix(8)) "
                    + "— pids \(existing.pid) and \(session.pid); keeping \(existing.pid)")
                continue
            }
            liveById[session.sessionId] = session
        }
        // The topic is the stored brief's composed 3–6-word label, carried by
        // the waiting query's brief join — NEVER a prose prefix of summaryText
        // or the raw assistant message (ruled: that derivation produced orphan
        // fragments like "**Voices for lif"). No brief yet = name only.
        // Turn boundaries serve BOTH bands now: waiting() keeps a heard-but-
        // unanswered session in this band, and if the user answered it IN THE
        // TERMINAL the agent is already chewing — green ("you have not
        // answered this") would be a lie, so the transcript's verdict wins.
        let boundaries = (try? store?.latestTurnBoundaries()) ?? [:]
        var rows = waiting.map { (event: WaitingSession) -> StateLegend.SessionRow in
            let activity = event.transcriptPath.flatMap {
                SessionActivity.read(transcriptPath: $0,
                                     boundary: boundaries[event.sessionId])
            }
            // Green says "you have not answered this". While a reply to
            // this very turn is in flight that is the most misleading thing
            // the grid can say — the cursor does not advance until the send
            // confirms, so the row goes on asking for the user seconds after
            // they spoke to it. A newer turn arriving still wins: see
            // DeliveryInFlight.supersedesWaiting. A terminal reply wins the
            // same way: the transcript says working, so the row does too.
            return StateLegend.SessionRow(
                id: event.sessionId,
                name: tabDisplayName(for: event, live: liveById[event.sessionId]),
                // The id, not the callsign — ruled 12 Aug, and the same in
                // every band so a row means the same thing wherever it sits.
                aux: StateLegend.shortId(event.sessionId),
                lamp: activity == .working
                    || delivering.supersedesWaiting(event.sessionId, latestId: event.latestId)
                    ? .working : .ready,
                // This band is the only one with a real read state: these
                // rows HAVE a waiting turn. Everywhere else the answer is
                // `.none`, which rests at the same intensity as `.opened`
                // (16 Aug) — an idle session is not asking for you either.
                read: event.heard ? .opened : .unread)
        }
        // Live sessions with nothing waiting: quiet rows, so a skipped or heard
        // session stays findable. Walked via `known` — already latestId DESC —
        // so the band is recency-ordered like the waiting band above it, never
        // Dictionary.values hash order (which reshuffled between refreshes).
        // (Turn boundaries were computed above the waiting band — see
        // SessionActivity.classify's precedence note: the hooks settle
        // working-vs-idle, which the transcript alone gets wrong 9.8% of the
        // time an agent is working.)
        let waitingIds = Set(waiting.map(\.sessionId))
        let known = (try? store?.allKnownSessions()) ?? []
        // Minted callsigns outlive the process that earned them, so a dead row
        // keeps the name you have been calling it. The store is the only place
        // this exists — nothing on disk records what we named a session.
        let closedCallsigns = Dictionary(
            known.compactMap { row in row.callsign.map { (row.sessionId, $0) } },
            uniquingKeysWith: { first, _ in first })
        var placed = waitingIds
        for stored in known where !placed.contains(stored.sessionId) {
            guard let live = liveById[stored.sessionId] else { continue }
            // Ruled 12 Aug: headless is headless whether it is running or not.
            // Liveness used to hide these by accident — a cron job is gone
            // before anyone looks — but a LONG one is live and got a row, and
            // then vanished on exit instead of joining the closed band. One
            // rule across all four bands now, and it is the same fail-open
            // predicate the announcer uses.
            guard !SessionDiscovery.isHeadless(transcriptPath: stored.transcriptPath)
            else { continue }
            placed.insert(stored.sessionId)
            let activity = stored.transcriptPath.flatMap {
                SessionActivity.read(transcriptPath: $0,
                                     boundary: boundaries[stored.sessionId])
            }
            rows.append(StateLegend.SessionRow(
                id: stored.sessionId,
                name: tabDisplayName(for: stored, live: live),
                aux: activity?.shortReason ?? StateLegend.shortId(stored.sessionId),
                lamp: lamp(for: activity, sessionId: stored.sessionId)))
        }
        // Live sessions with no stored events yet: nothing to rank them by,
        // so they close the live half of the grid.
        for live in liveById.values where !placed.contains(live.sessionId) {
            let path = live.cwd.map {
                TranscriptTitles.defaultPath(cwd: $0, sessionId: live.sessionId)
            }
            // A session with no stored events has no recorded transcript path,
            // so this is the one band that has to derive one. `defaultPath`
            // rebuilds it from the two fields the agents API supplies, and an
            // unreadable path fails open exactly like everywhere else.
            guard !SessionDiscovery.isHeadless(transcriptPath: path) else { continue }
            placed.insert(live.sessionId)
            let activity = path.flatMap {
                SessionActivity.read(transcriptPath: $0,
                                     boundary: boundaries[live.sessionId])
            }
            rows.append(StateLegend.SessionRow(
                id: live.sessionId,
                name: StateLegend.displayName(
                    liveName: Self.tabTitle(transcriptPath: nil, live: live),
                    callsign: nil, fallback: "session"),
                aux: activity?.shortReason ?? StateLegend.shortId(live.sessionId),
                lamp: lamp(for: activity, sessionId: live.sessionId)))
        }
        // And the sessions that are not awake (ruled 11 Aug). Everything above
        // this line is enumerated from PROCESSES, which is why a machine
        // restart used to empty the panel; everything below is enumerated from
        // the transcripts on disk, which outlive the process.
        //
        // Deliberately ADDITIVE rather than a replacement of the bands above.
        // The live half already agrees with the store and with the announcer;
        // rebuilding it from disk would give the same rows by a second route,
        // and two routes to one answer is how they start disagreeing. Disk
        // enumerates only the population the process list cannot: the dead.
        for found in (SessionDiscovery.discoverIfScanned()?.sessions ?? [])
        where !placed.contains(found.sessionId) && found.liveness != .live {
            placed.insert(found.sessionId)
            rows.append(StateLegend.SessionRow(
                id: found.sessionId,
                name: StateLegend.displayName(
                    liveName: found.title,
                    callsign: closedCallsigns[found.sessionId],
                    fallback: found.cwd.map { ($0 as NSString).lastPathComponent } ?? "session"),
                // Same precedence as the live band above: a session that died
                // mid-error says why, and otherwise the column carries the id.
                // For a closed row that id is the whole point — it is the
                // thing you would otherwise be grepping ~/.claude/projects for.
                aux: found.activity?.shortReason
                    ?? StateLegend.shortId(found.sessionId),
                lamp: .unlit,
                revivable: found.revivable))
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

    /// Redraw the grid against a liveness answer taken AFTER the kill.
    ///
    /// `sessionRowsNow()` reads the same cached probe as everything else, and
    /// that cache is six seconds deep — long enough that a row for a session the
    /// user has just ended would keep its lamp lit, offer to announce, and read
    /// as a control that ignored a click. Dropping the cache first is the whole
    /// difference between "ended" and "ended, eventually".
    ///
    /// Only ever called with the grid as the destination, so a card the user is
    /// reading is not yanked out from under them: this repaints the face the
    /// right-click happened on.
    private func refreshGridAfterTerminate() {
        ClaudeAgentsCLI.invalidate()
        guard case .idle = hud.state else { return }
        showIdleGrid()
    }

    /// Arm the receipt's return (ui-pass-7, ruling 5): the receipt has said
    /// its piece, it holds for the delay, and if the panel is still on it —
    /// no gesture moved it — the grid comes back. ONLY the receipt dwells
    /// this way now: the spoken card stays until a gesture moves it (ruling
    /// 14 reversed, 12 Aug), and the `.receipt`-only guard below is the
    /// backstop — an arm from a speaking path fires into a no-op rather
    /// than yanking a card someone is still reading.
    private func scheduleReturnToGrid() {
        returnToGridWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.hud.state {
            case .receipt: break
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
        // grid underneath it (the receipt's timer dies on contact; the spoken
        // card has no timer at all — ruling 14 reversed, 12 Aug). The arm
        // window is the one exception — arming is SPECULATION about a hold
        // that may turn out to be a tap or a typing chord, so it must not
        // consume the receipt's clock; the abort path restarts the clock when
        // its revert lands back on the receipt.
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
                // ⌥⌥ from the read-back is Don't send, then ⌥⌥ (ruled 18 Aug).
                // It was not: this path opened a new capture and never touched
                // the countdown, so four seconds later the words the gesture had
                // just rejected were dispatched into a live microphone (app.log
                // 22:39:05). The hold path has always said these two lines; the
                // tap path never got them. `StatusHUD.releasePendingSend` now
                // catches the whole class at the door — this stays because the
                // ORDER is a ruling in its own right, and the door cannot know it.
                //
                // BEFORE the microphone, unlike every mutation below it. The
                // 10 Aug rule ("nothing is mutated until the microphone is
                // actually recording") protects a waiting agent you could LOSE to
                // a failed open; this is the opposite kind of mutation. You asked
                // for these words NOT to be sent, and a microphone that fails to
                // open is not a reason to send them. A failure lands on the mic
                // card with the transcript discarded — kept in past utterances,
                // out of the sendable set — which is where Don't send leaves it
                // too. Same order `.replyBegan` already uses for the hold.
                //
                // The generation bump is not decoration and it is not the fix:
                // `send(utteranceId:)` reads the generation when the timer FIRES,
                // so it can never catch a countdown. What it does catch is the
                // sibling case one state over — ⌥⌥ during `.transcribing`, which
                // also admits `.listening` — where the replaced transcription
                // would otherwise finish and open a read-back for the old words
                // while you are already speaking the new ones.
                replyGeneration += 1
                hud.cancelPendingSend(restartListening: false)
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
                // Same rule as the tap path above: a launch in flight owns the
                // reply, and the routing ladder must not be allowed to answer
                // for it.
                if let launch = pendingLaunch, launch.isPending {
                    recordingLaunch = launch
                    recordingTarget = nil
                } else if let ctx = context {
                    recordingLaunch = nil
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
                let spoken = await coordinator.speech.speak(
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
                // Ruling 14 reversed (12 Aug): a finished rung dwells. No clock —
                // the reader decides when a pull has been read, so the only exits
                // from this card are gestures. `completed` is still read rather
                // than discarded (`_ = await` hid a provider lying about early
                // returns once already); an unfinished rung is still worth a line.
                if !spoken.completed {
                    Permissions.log("ladder: rung did not complete")
                }
                rebuildMenu()
            }

        case .armWindowOpened(let pressedAt):
            // Instant-arm (docs/instant-arm.md): bare ⌥ survived the grace.
            // Speculative on purpose — a tap or a chord fully unwinds it.
            guard micGranted else { return }
            // A wedged machine will refuse the open anyway; refusing here
            // skips painting an arming face that would only revert.
            guard recorder.allowsAutoArm else {
                Permissions.log("arm: skipped, mic machine wedged")
                return
            }
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
            // If the revert landed back on the receipt, its clock — which this
            // gesture deliberately never cancelled, but whose work item may have
            // fired into the arming window and consumed itself — restarts. The
            // spoken card dwells (ruling 14 reversed, 12 Aug), so it re-arms
            // nothing.
            switch hud.state {
            case .receipt: scheduleReturnToGrid()
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
            // The agent you just launched owns this reply, even though it has
            // no id yet. Resolving the routing here would walk past it to the
            // PREVIOUS agent — the misroute this exists to end — so the launch
            // is remembered instead and the words wait for it at submit time.
            if let launch = pendingLaunch, launch.isPending {
                recordingLaunch = launch
                recordingTarget = nil
            } else if let ctx = resolveReplyContext() {
                recordingLaunch = nil
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
            guard let capture = try? recorder.stop() else {
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
            sendReply(capture)

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
            // Same overlay as the selection below, or this emptiness check
            // says "something is waiting" about the very turn we are about to
            // refuse to announce, and the grid never gets shown.
            //
            // Nothing unopened does NOT mean nothing to play (ruled 13 Aug):
            // anything green always plays. When every waiting row has been
            // opened, ⌃⌥ WALKS them — the next one after whatever it played
            // last, wrapping — through the explicit path a row tap uses.
            //
            // Two bugs on this keypress, in order. First it bounced to the
            // grid in silence, which read as a dead app (13 Aug 14:26). The
            // fix replayed `waiting().first`, which is the same row every
            // time, so ⌃⌥ welded itself to one session: five presses, five
            // `replaying 4394c0ec` (16 Aug 01:04). ⌃⌥ means "next", and it
            // has to mean that on the opened stack too.
            //
            // `lastReplayed` is the walk's only state and it is deliberately
            // in-memory: a restart should open at the top of the stack, not
            // resume a walk nobody remembers taking.
            var replayId: String?
            if eventId == nil,
               (try? coordinator.nextToAnnounce(excluding: self.delivering)) == nil {
                replayId = ((try? coordinator.nextToReplay(
                    after: self.lastReplayed, excluding: self.delivering)) ?? nil)?.sessionId
                guard let replayId else {
                    lastReplayed = nil
                    showIdleGrid()
                    return
                }
                lastReplayed = replayId
                Permissions.log("announce: all opened — replaying \(replayId.prefix(8))"
                    + " (walk)")
            } else {
                // A fresh unopened turn, or an explicitly named session, ends
                // the walk: the next ⌃⌥ over an all-opened stack starts from
                // the top rather than continuing a walk the user interrupted.
                lastReplayed = eventId
            }
            Permissions.log("announce: starting")
            do {
                // A tap is an explicit request to hear something, so the
                // interruptibility gate does not apply — you cannot interrupt
                // someone who just asked.
                let outcome = try await coordinator.announceNext(
                    only: eventId ?? replayId,
                    ignoringGate: true,
                    excluding: self.delivering,
                    onWillSpeak: { [weak self] announcement in
                        // Render BEFORE the audio starts. Showing it afterwards is
                        // useless — you have already heard the whole thing by then.
                        guard let self else { return false }
                        let live = (ClaudeAgentsCLI().sessions() ?? [])
                            .first { $0.sessionId == announcement.event.sessionId }
                        // One displayed identity (re-ruled 05 Aug): the terminal
                        // tab's own string. It is now the ONLY identity — the
                        // voice stopped speaking the callsign on 18 Aug, so the
                        // eye and the ear have nothing left to disagree about.
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
                    // Ruling 14 reversed (12 Aug): fully spoken dwells. The card
                    // stays until a gesture moves it — the grid is one tap away,
                    // not four seconds away.
                case .interrupted(let failure):
                    if let failure {
                        // Nobody asked for this one. Say so, rather than letting a
                        // dropped connection masquerade as something you chose.
                        // A failure writes no cursor, so "still unread" is true.
                        lastStatusLine = "playback failed, still unread"
                        hud.showResult(
                            "Playback failed (\(failure)). It's still waiting. "
                            + "tap ⌃⌥ to hear it again.")
                    } else {
                        // No read-state claim here: stopping it yourself OPENS
                        // the turn (13 Aug), stopping it before any audio does
                        // not, and the grid's row weight now shows which one
                        // happened — copy that guessed would lie half the time.
                        lastStatusLine = "stopped"
                        showIdleGrid(note: "Stopped.")
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
                // A deep link may not record. It is the one rule this surface
                // has that the others do not need: any page in any browser can
                // fire one of these, and a link that opens a live microphone is
                // a page deciding you had something to say. The browser's
                // consent sheet is not consent to be recorded — it is consent
                // to open an app.
                //
                // So this lands you on the agent with the reply ARMED and waits
                // for a gesture you make yourself. One ⌥ tap and you are
                // speaking, which is the same gesture the card has always used;
                // the link's job ends at putting the target in front of you.
                _ = try? coordinator?.intake()
                // The page names its session; that is the whole point of the
                // button. Unknown id → say so, never fall back to a guess about
                // which agent your words belong to.
                guard let session,
                      let target = try? store?.allKnownSessions()
                          .first(where: { $0.sessionId == session }) else {
                    hud.showResult("That page's agent isn't in the log.")
                    break
                }
                guard !recorder.isRecording else { break }
                let live = (ClaudeAgentsCLI().sessions() ?? [])
                    .first(where: { $0.sessionId == session })
                let name = tabDisplayName(for: target, live: live)
                hud.adoptTarget(sessionId: session, pid: live?.pid,
                                label: name, cwd: target.cwd)
                recordingTarget = session
                activeConversation = (session, name, target.cwd)
                showPanel()
                announceNext(only: session)
                if !micGranted {
                    // Said once, on arrival, rather than discovered at the press.
                    hud.note("The microphone isn't granted — Settings ▸ Privacy ▸ "
                             + "Microphone before you can reply.")
                }
            case "home":
                // The agent's own page. Written after every turn, so it exists
                // for any session that has ever been summarized; for one that
                // has not, there is nothing to show and the invitation is the
                // honest answer.
                if session.map({ openHub(session: $0) }) != true {
                    inviteNewSession(for: ref)
                }
            case "show":
                showPanel()
            default:
                Permissions.log("deeplink: unknown action \(action)")
            }
        }
    }

    /// The one report this turn just wrote, if any: the newest recorded
    /// artifact, on disk, stamped after the PREVIOUS turn's brief — which is
    /// when this turn began. An artifact from an earlier turn is the hub's
    /// job; an artifact re-touched but first recorded long ago keeps its
    /// first stamp and stays with the hub too, deliberately.
    private func freshReport(session: String) -> String? {
        guard let store,
              let latest = ArtifactStore.history(
                  for: session, root: QueueStore.supportDirectory.path).last
        else { return nil }
        let briefs = (try? store.briefs(for: session, limit: 2)) ?? []
        let turnBegan = briefs.count > 1
            ? Date(timeIntervalSince1970: Double(briefs[1].atMs) / 1000)
            : .distantPast
        return latest.at > turnBegan ? latest.path : nil
    }

    /// The hub, rewritten fresh and then shown. One code path for both of its
    /// doors — the card's second door and the `home` deep link — so the page
    /// the button opens and the page the link opens cannot drift. Returns
    /// false when the session has no briefs yet, and the caller decides what
    /// an absent hub means (the card hides the door; the deep link invites).
    @discardableResult
    private func openHub(session: String) -> Bool {
        guard let store,
              let file = try? HomeBase.write(sessionId: session, store: store)
        else {
            Permissions.log("openHub: no briefs for \(session.prefix(8))")
            return false
        }
        if BrowserFocus.focusExistingTab(file) == .notFound {
            NSWorkspace.shared.open(file)
        }
        return true
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

    private func sendReply(_ capture: Recorder.Capture) {
        guard let coordinator else { return }
        // Unpacked once, at the top, from the value stop() returned. Both of
        // these used to be read separately — the samples from the return, the
        // file from mutable state on the recorder — which is how a later capture
        // could have replaced one without the other.
        let pcm = capture.pcm16
        let capturedFile = capture.fileURL
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
                        streamed: streamed, preWritten: capturedFile)
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
                // The words wait for the agent they were spoken to.
                //
                // A capture that began on a greeting card carries the LAUNCH,
                // not a session id, because there was no session when you
                // started talking. By the time a reply has been spoken and
                // transcribed the agent has almost always registered — five to
                // nine seconds, against a reply that takes at least as long —
                // so this usually returns instantly. When it does not, waiting
                // is still the right answer: the alternative that shipped was
                // typing your words into the previous agent without saying so.
                var resolvedTarget = recordingTarget
                if resolvedTarget == nil, let launch = recordingLaunch {
                    lastStatusLine = "waiting for \(launch.label) to come up…"
                    rebuildMenu()
                    resolvedTarget = await launch.session(timeout: 30)
                    let waited = Int(Date().timeIntervalSince(launch.startedAt))
                    Permissions.log("launch: reply waited \(waited)s for \(launch.label) — "
                        + (resolvedTarget.map { "went to \($0.prefix(8))" } ?? "never came up"))
                }
                guard let spokenTo = resolvedTarget else {
                    // Two ways to be here, and they are different failures. A
                    // launch that never came up is the one this path exists for:
                    // the agent is genuinely absent, so the words go where you
                    // can still get at them rather than into somebody else's tab.
                    if let launch = recordingLaunch {
                        recordingLaunch = nil
                        Permissions.log("send: \(launch.label) never registered; nothing sent")
                        hud.showResult("\(launch.label) never came up — nothing was sent. "
                                       + "Your words are kept; check Terminal for a prompt.")
                    } else {
                        Permissions.log("send: recording has no captured address; refusing")
                        hud.showResult("This recording lost its address. Audio kept; nothing sent.")
                    }
                    rebuildMenu()
                    return
                }
                recordingTarget = nil
                recordingLaunch = nil
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
                    preWritten: capturedFile)

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
        // Only advise the built-in mic if capture has not already tried it. Once
        // the open loop has retreated there and STILL failed, telling the user to
        // switch to the device that just failed is worse than no advice.
        if recorder.fellBackToBuiltIn {
            return "Couldn't open the built-in microphone either — try again. (\(error))"
        }
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
        // Rebuild now rather than on the next press, for the same reason launch
        // does: a preference change means a new device, and a gesture is the
        // one place that cannot absorb the unit rebuild. Still the single code
        // path — warmUp prepares the unit and remains the only thing that
        // decides which device is live (and it retires any built-in retreat).
        recorder.warmUp()
        rebuildMenu()
    }

    @objc private func chooseVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Two catalogues, two settings. Writing a macOS identifier into
        // `selectedVoiceId` would store it where only ElevenLabs reads, so the pick
        // would appear to take and change nothing audible — the same class of silent
        // no-op as the preview that played one voice for every row.
        if SystemVoiceCatalog.isSystemVoice(id) {
            SystemVoiceCatalog.choose(id)
            // No rebuild needed: SystemSpeechProvider resolves the preference per
            // utterance, so the next announcement uses it.
        } else {
            VoiceCatalog.selectedVoiceId = id
        }
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
    private func surfaceArrival(rows: [StateLegend.SessionRow], waiting: Int,
                                newlyWaiting: Bool) {
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
        // The hail path. Without the overlay the frontmost-tab check below is
        // run against the session you just answered rather than the one that
        // actually arrived — the same defect as ⌃⌥, wearing a different symptom.
        let target = try? coordinator?.nextToAnnounce(excluding: delivering)
        // The frontmost-tab skip needs three subprocesses (osascript, the
        // claude CLI, ps), and it used to run them ON MAIN, synchronously —
        // issue 14's smaller resident: with Terminal frontmost AND busy, one
        // Apple event here could hold the app for minutes, on every arrival.
        // Terminal-not-frontmost is the common case and stays fully
        // synchronous: no probe, no reordering, identical behavior.
        let terminalIsFront = NSWorkspace.shared.frontmostApplication?
            .bundleIdentifier == "com.apple.Terminal"
        guard terminalIsFront, let target else {
            finishArrival(rows: rows, waiting: waiting, newlyWaiting: newlyWaiting)
            return
        }
        // Terminal IS frontmost: probe off-main, newest arrival wins. A newer
        // call bumps the generation, so a stale probe returns to find its
        // moment gone and stays silent — the newer one carries the chime.
        arrivalProbeGeneration += 1
        let generation = arrivalProbeGeneration
        pendingArrival = (rows, waiting, newlyWaiting)
        let sessionId = target.sessionId
        Task.detached(priority: .userInitiated) { [weak self] in
            let front = await Self.frontmostTerminalTabTty()
            let pid = front == nil ? nil : (ClaudeAgentsCLI().sessions() ?? [])
                .first(where: { $0.sessionId == sessionId })?.pid
            let onScreen = pid.flatMap { ProcessProbe.tty(of: $0) }
            let skip = front != nil && onScreen == front
            await MainActor.run { [weak self] in
                guard let self, generation == self.arrivalProbeGeneration,
                      let pending = self.pendingArrival else { return }
                self.pendingArrival = nil
                if skip {
                    // You are looking straight at the tab that just finished.
                    // Announcing it is telling you something you can already
                    // see — no panel, no hail: showing up is enough, and here
                    // you are already there.
                    Permissions.log("ambient: skipped, that session is the frontmost tab")
                    return
                }
                self.finishArrival(rows: pending.rows, waiting: pending.waiting,
                                   newlyWaiting: pending.newlyWaiting)
            }
        }
    }

    /// One probe in flight, newest wins; the pending rows never cross an
    /// isolation boundary — they wait here for the probe's verdict.
    private var arrivalProbeGeneration = 0
    private var pendingArrival: (rows: [StateLegend.SessionRow], waiting: Int,
                                newlyWaiting: Bool)?

    /// The away-channel tail of an arrival, after the gates have spoken.
    private func finishArrival(rows: [StateLegend.SessionRow], waiting: Int,
                               newlyWaiting: Bool) {
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
            if newlyWaiting { Earcons.play(.returned, gate: earconGate()) }
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
        // Sound only on a session JOINING the waiting set — see `lastWaitingIds`.
        // The panel repaint above is unconditional and stays that way: currency is
        // not attention, and a lamp on screen must be true even when nothing
        // announces itself.
        if newlyWaiting {
            Earcons.play(.returned, gate: earconGate())
        } else {
            Permissions.log("earcon: no returned — \(waiting) waiting, none of them new")
        }
    }


    /// The tty of Terminal's selected tab. One Apple event, bounded: against a
    /// busy Terminal an unbounded event blocks its thread for up to the
    /// two-minute default timeout, so the deadline is what keeps this callable
    /// at all. Callers check who is frontmost first — that part is free.
    nonisolated private static func frontmostTerminalTabTty() async -> String? {
        let script = "tell application \"Terminal\" to return tty of selected tab of front window"
        guard case .success(let out) = await AppleScript.run(script: script, timeout: 2)
        else { return nil }
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

    private func openSettings(tab: SettingsTab = .voices) {
        // Paid voices first, then the free ones the machine already has. Without the
        // second half this pane read "15 of 0 on roster" whenever no ElevenLabs key
        // was configured — an empty list on a Mac with forty voices installed, and no
        // hint that free ones exist at all.
        // Installed voices, then the good ones that are a download away. A picker
        // that shows only what you have cannot tell you what you are missing, and
        // what you are missing is the best of them.
        let paid = VoiceCatalog.cached()
        // The cached snapshot, same as the menu tick. The 1.5 s tick keeps it
        // no staler than ~15 s, and a sync read here is the same TTS-daemon
        // semaphore that froze the tick (issue 14) — a pane open must not
        // gamble on the daemon's mood either.
        let rows = SystemVoiceCatalog.cachedRows()
        let free = rows.catalogue
        let getMore = rows.downloads

        // One line. This was four sentences of explanation — a wall of prose where a
        // control belonged. The "Free · Get" rows below ARE the instruction now, so
        // the note only has to say what the list is.
        let note = paid.isEmpty
            ? "Free macOS voices. Pick one to hear it."
            : "Checked voices are the cast; agents draw one in roster order."

        hud.showSettings(voices: paid + free + getMore,
                         roster: VoiceRoster.load(), note: note, tab: tab)
    }

    /// The settings state's second pane (ruled 13 Aug): every capture over a
    /// second, newest first, with the transcript it has or the absence it
    /// doesn't, and a per-row manual retry. The log IS the utterances table;
    /// this only projects it.
    private func showRecentAudio() {
        hud.showRecentAudio(events: recentAudioEvents(),
                            note: "Captures over a second, newest first.")
    }

    /// A second is the noise floor: shorter rows are key-slips and arm
    /// discards, and a log that lists them buries the recordings a human
    /// might actually want back.
    private static let recentAudioFloorMs: Int64 = 1_000
    private static let recentAudioRowCap = 12

    private func recentAudioEvents(retrying: String? = nil) -> [StatusHUD.AudioEventRow] {
        guard let store else { return [] }
        let stamp = DateFormatter()
        stamp.dateFormat = "MMM d HH:mm"
        return ((try? store.utterances(limit: 200)) ?? [])
            .filter { ($0.audioDurationMs ?? 0) >= Self.recentAudioFloorMs }
            .prefix(Self.recentAudioRowCap)
            .map { u in
                let seconds = Int((u.audioDurationMs ?? 0) / 1000)
                let text = u.transcriptText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return StatusHUD.AudioEventRow(
                    id: u.id,
                    timeLabel: stamp.string(
                        from: Date(timeIntervalSince1970: Double(u.createdAtMs) / 1000)),
                    durationLabel: seconds >= 60
                        ? "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s"
                        : "\(seconds)s",
                    transcript: (text?.isEmpty ?? true) ? nil : text,
                    playing: u.id == utterancePlayer.playingId,
                    retrying: u.id == retrying)
            }
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

    /// Bring back a session whose process has ended.
    ///
    /// The row already checked that this session is gone and that its directory
    /// exists — but that check is as old as the last grid refresh, and the one
    /// thing that must not happen is resuming a session that came back to life
    /// in between. `claude --resume` on a live session adds a second process
    /// under the same id, and that crashed the app twice. So the guard is taken
    /// AGAIN here, on a fresh probe, at the moment of the act.
    ///
    /// Off-main because it drives Terminal through AppleScript.
    /// The graveyard, built once and handed over whole.
    ///
    /// Every interactive session in the window, live ones included: the job is
    /// "I don't know which tab that workstream is in", and a session you left
    /// running in a tab you have lost is exactly as hard to find as a dead one.
    /// The verb differs — a live row goes to its tab, a dead one comes back —
    /// and the row already knows which it is.
    ///
    /// Off-main because the scan can walk the archive, then applied on the main
    /// actor in one shot.
    private func openPastAgents() {
        // The SAME rows the grid is built from, minus the ones it is showing.
        // Not a second query: two queries can disagree, and the disagreement
        // was visible — every live session appeared in both surfaces at once,
        // and appeared here with a quiet lamp whatever it was actually doing.
        // A working agent read as idle, which is the lamp lying.
        let rows = sessionRowsNow()
        let hidden = Array(StatusHUD.pastAgents(rows))
        // The directory is the one thing a row does not carry and the filter
        // wants, so it comes from the scan the rows were built from — already
        // warm, since sessionRowsNow just used it.
        let cwds = Dictionary(
            (SessionDiscovery.discoverIfScanned()?.sessions ?? [])
                .map { ($0.sessionId, $0.cwd ?? "") },
            uniquingKeysWith: { first, _ in first })
        let items = hidden.map { row -> PastAgentsList.Item in
            // Everything the filter matches, lowercased once: the name you half
            // remember, the id you would have grepped for, and the directory you
            // were working in.
            let haystack = [row.name, row.id, cwds[row.id] ?? ""]
                .joined(separator: " ").lowercased()
            // The row's OWN lamp, carried through. A session below the fold is
            // usually quiet, but it is not quiet by definition — on a small
            // screen an agent can be working and still not fit — and the lamp
            // must say which.
            return PastAgentsList.Item(row: row, revivable: row.revivable,
                                       haystack: haystack)
        }
        hud.showPastAgents(items: items)
    }

    /// Focus a live session's terminal tab, from the list.
    private func goToSession(_ sessionId: String) {
        Task.detached {
            guard let live = (ClaudeAgentsCLI().sessions() ?? [])
                .first(where: { $0.sessionId == sessionId }) else {
                Permissions.log("goTo: \(sessionId.prefix(8)) is not live any more")
                return
            }
            _ = SessionLauncher.focus(pid: live.pid)
        }
    }

    private func revive(_ sessionId: String, name: String) {
        hud.showReceipt(.reviving(name))
        Task.detached {
            let fresh = SessionDiscovery.discover(ttl: 0).sessions
                .first { $0.sessionId == sessionId }
            guard let fresh, let command = fresh.reviveCommand else {
                // One receipt per reason (18 Aug). `alreadyAwake` used to answer
                // for all four, and it is only true for the first — so the
                // panel's single word on a refusal was false in the three cases
                // that are not "it came back on its own". That was survivable
                // while REVIVE was a hover verb on a list; it is not, now that
                // the lamp is the switch and this is what the switch says back.
                let why = fresh?.liveness
                Permissions.log("revive: refused \(sessionId.prefix(8)) — "
                    + (fresh.map { "liveness \($0.liveness.rawValue)" } ?? "no longer on disk"))
                await MainActor.run { [weak self] in
                    switch why {
                    case .live:
                        self?.hud.showReceipt(.alreadyAwake)
                    // `gone` with no revive command means the one other thing
                    // `revivable` tests: the launch directory is no longer there,
                    // so `--resume` would land nowhere.
                    case .gone:
                        self?.hud.showReceipt(.notRevived("its directory is gone"))
                    case .unknown:
                        self?.hud.showReceipt(.notRevived("can't tell if it's running"))
                    case nil:
                        self?.hud.showReceipt(.notRevived("no longer on disk"))
                    }
                }
                return
            }
            // Say what it was doing, the moment you ask for it back (ruled
            // 18 Aug: "revive likewise should basically work the same — if
            // you're reviving, it should reopen the agent message").
            //
            // Announced BEFORE the resume rather than after, and not waiting on
            // it: unlike a launch, a revived session already has a brief, so
            // there is nothing to synthesize and nothing to wait for. The same
            // door a launch greeting uses, which means the same voice — this
            // session's own, assigned long ago — and the same reply routing,
            // under the same id, because `--resume` keeps it.
            //
            // A reply that beats the process back is not lost: dispatch checks
            // readiness and says "can't take this yet, your words are kept."
            await MainActor.run { [weak self] in self?.announceNext(only: sessionId) }
            _ = SessionLauncher.resume(sessionId: sessionId, directory: command.cwd)
        }
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
        // No greeting here. This session was started FOR something and the card
        // that offered it already said what; asking "how would you like to get
        // started?" over the top of an answered question is the app talking to
        // itself.
        newSession(directory: directory, command: command, greet: false)
    }

    /// Off-main like `revive()`: `launch()` drives Terminal through AppleScript
    /// and then watches the new tab for the trust prompt — its own doc says
    /// "call off-main". Until 12 Aug this ran on the main actor, and every
    /// NEW AGENT click beach-balled the app for the watcher's full 30s
    /// (app.log 22:00:24→22:00:59: launched, then "no trust prompt seen
    /// within 30s", with the main thread asleep in between).
    /// `greet` is false for the one launch that arrives already knowing what it
    /// is for — the artifact invitation, which hands the session its opening
    /// prompt. Everywhere else the greeting is the point: a launched agent is a
    /// waiting agent, and it says so.
    private func newSession(directory dir: String, command: String, greet: Bool = true) {
        let label = (dir as NSString).lastPathComponent
        let line = LaunchGreeting.nextLine()

        // The card, FIRST — before Terminal is asked to do anything (ruled
        // 18 Aug). Painting after the launch meant painting after a window
        // opened, a CLI came up, a trust watcher settled and an id appeared in
        // `claude agents --json`: seconds of nothing, in answer to a button.
        // None of that is a precondition for asking the question, so none of it
        // is waited on. The session is attached underneath when it exists.
        // The voice this agent is about to be given, asked for before it has an
        // id to be given it under (ruled 18 Aug: "it should be the actual voice
        // for the agent, not a temporary one-off"). The greeting used the app's
        // own narrator, so a session introduced itself as one person and came
        // back as another the first time you pressed ⌃⌥. The peek is bound to
        // the session at registration, so the two cannot diverge.
        let voice = (try? store?.nextVoiceInRotation(roster: VoiceRoster.load())) ?? nil
        // The promise the card's answer waits on. Created with the card, because
        // the whole point of the card is that you may answer it before there is
        // an agent to answer — see PendingLaunch for what that cost before.
        let launch = greet ? PendingLaunch(label: label, directory: dir) : nil
        if let launch { pendingLaunch = launch }
        if greet, hud.showGreeting(line: line, label: label) {
            // Through the greeting cache, which is what it is for: one fixed
            // sentence per voice, synthesized once and replayed from disk
            // forever after — no model call, no round trip, no waiting for a
            // brief that has not been written yet. Detached because the audio
            // is not the panel's business and the panel is already up.
            Task.detached(priority: .userInitiated) {
                await GreetingCache.speak(line, voiceId: voice)
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let before = Set((ClaudeAgentsCLI().sessions() ?? [])
                .filter { $0.cwd == dir }.map(\.sessionId))
            // `acceptTrustPrompt: false` — we run that watcher ourselves, in
            // parallel, immediately below. It blocks for at least two settled
            // polls and up to thirty seconds, and until now the registration
            // this greeting binds to queued behind it.
            let result = SessionLauncher.launch(directory: dir, command: command,
                                                acceptTrustPrompt: false)
            guard case .success(let tty) = result else {
                // Every exit from here on releases the promise. A waiter left
                // hanging is a reply that never lands and never says why, which
                // is the one outcome worse than the misroute this replaces.
                launch?.abandon()
                if case .failure(let error) = result {
                    await MainActor.run { [weak self] in
                        self?.hud.showResult("Couldn't start an agent: \(error.message). "
                                             + "Terminal automation permission is the usual suspect.")
                    }
                }
                return
            }
            Task.detached(priority: .utility) {
                SessionLauncher.watchForTrustPrompt(tty: tty)
            }
            await MainActor.run { [weak self] in
                self?.lastStatusLine = "new session launched"
                self?.rebuildMenu()
            }

            // First-run reality (ruled, docs/ws-b-ruling.md): the
            // directory-trust prompt is a security consent and is NEVER
            // auto-answered when it needs a human. If nothing registers, say so
            // — a walked-away launch must not be a silently stillborn
            // investigation.
            guard let sessionId = LaunchGreeting.awaitRegistration(
                directory: dir, excluding: before) else {
                launch?.abandon()
                Permissions.log("launcher: no session registered in \(dir) after 30s")
                await MainActor.run { [weak self] in
                    guard let self, self.hud.canSurfaceAmbiently else { return }
                    self.showIdleGrid(note: "New agent is waiting on a prompt in Terminal.")
                }
                return
            }

            // Kept BEFORE the greeting row is written and before the card is
            // bound: the promise is about the SESSION EXISTING, which is now
            // true, and it must not be hostage to a store write or to whether
            // the card is still on stage. Binding can fail — it does, whenever
            // you started talking — and the words must reach the agent anyway.
            launch?.resolve(sessionId: sessionId)
            guard greet, let store = await self?.store else { return }
            let pid = (ClaudeAgentsCLI().sessions() ?? [])
                .first(where: { $0.sessionId == sessionId })?.pid
            do {
                // The durable half. The card is already on screen; this is what
                // makes it a row in the grid, a reply target, and a turn the
                // session's own first Stop supersedes. nil means the session
                // already carries its greeting.
                guard try LaunchGreeting.record(sessionId: sessionId, directory: dir,
                                                line: line, voice: voice, tty: tty,
                                                store: store) != nil
                else { return }
                Permissions.log("greeting: recorded for \(sessionId.prefix(8)) in \(dir)")
            } catch {
                // The agent is up either way. A greeting that failed to land
                // costs a trip to the terminal, which is exactly where we were
                // before it existed.
                Permissions.log("greeting: not recorded for \(sessionId.prefix(8)): \(error)")
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The card acquires its session, and with it the doors and the
                // reply routing. `activeConversation` is the same claim in the
                // host's language — your attention is on this agent, so the
                // next thing you say goes to it rather than to whatever a
                // cursor last pointed at.
                if self.hud.bindGreeting(sessionId: sessionId, pid: pid,
                                         label: label, cwd: dir) {
                    self.activeConversation = (sessionId, label, dir)
                    Permissions.log("greeting: bound \(sessionId.prefix(8)) to the card")
                } else {
                    // The refusal was the only step in this flow that changes
                    // where your words go and left no trace: three misroutes on
                    // 18 Aug were visible in app.log only as a MISSING line, and
                    // reconstructing them took a timeline built from absence.
                    // A refusal is a fact about a launch, so it gets a fact in
                    // the ledger.
                    Permissions.log("greeting: NOT bound \(sessionId.prefix(8)) — "
                        + "card moved on; replies go to the previous agent until PR B")
                }
            }
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

    /// What one menu rebuild cost, split by section. Milliseconds.
    ///
    /// Only the drill reads this. `rebuildMenu()` keeps its own signature and
    /// its own call sites untouched, because it runs on a poll tick and the
    /// measurement must not become something the tick pays for.
    struct RebuildCost { var total = 0.0; var voices = 0.0; var mic = 0.0 }

    private var lastRebuildCost = RebuildCost()

    private func timedRebuildMenu() -> RebuildCost {
        let t0 = Date()
        rebuildMenu()
        var cost = lastRebuildCost
        cost.total = Date().timeIntervalSince(t0) * 1000
        return cost
    }

    private func rebuildMenu() {
        var cost = RebuildCost()
        defer { lastRebuildCost = cost }
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
        // Free voices belong here too. This submenu listed ElevenLabs voices only and
        // grouped by ElevenLabs categories, so with no key `voices` was empty and the
        // whole Voice menu silently vanished — the same fault as the pane, on the
        // other of the two surfaces. Fixing one and not the other is why the change
        // looked like it had not landed.
        // The snapshot read is instant by contract: this runs on the MAIN
        // thread every 1.5 s poll tick, and the direct catalogue walk here —
        // a TextToSpeech semaphore plus four plists — is the nested blocker
        // in issue 14's spindump. The cache revalidates off-thread; the next
        // tick paints whatever it found.
        let voicesStart = Date()
        let rows = SystemVoiceCatalog.cachedRows()
        let voices = VoiceCatalog.cached() + rows.catalogue + rows.downloads
        if !voices.isEmpty {
            let item = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let selected = VoiceCatalog.selectedVoiceId
            // Free groups first — they are what most machines have, and on a machine
            // with no key they are all there is.
            for group in ["Free · Premium", "Free · Enhanced", "Free · Basic", "Free · Get",
                          "cloned", "generated", "professional", "premade"] {
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
        cost.voices = Date().timeIntervalSince(voicesStart) * 1000

        // Microphone, here rather than in the settings pane, for the same reason
        // the voice picker is here: it is a one-click choice, not an editor. The
        // pane is a roster editor with its own drag-ordering face; a two-item
        // radio group does not belong in it.
        //
        // The entries name the resolved DEVICE, not the policy. "System default"
        // tells you nothing about whether you are about to record through the
        // earbuds that will fail — which is why the warning marks auto-detect and
        // not just the Bluetooth entry.
        let micStart = Date()
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let preference = AudioInputPreference.current
        for option in AudioInputPreference.allCases {
            // The SNAPSHOT, not the hardware: this runs on the 1.5 s poll
            // tick, and the live read costs a median of 34 ms and a p99 of
            // one second when it is spaced the way a tick spaces it (measured
            // 18 Aug; see AudioInputDevice.cachedResolve). Every call site
            // that opens the microphone still reads live.
            let resolved = AudioInputDevice.cachedResolve(option)
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
        // Say when the preference is not what is actually recording. A tick beside
        // "System default (Robert's AirPods Pro)" while capture has retreated to
        // the built-in mic is a menu describing an intention, not a state.
        if recorder.fellBackToBuiltIn {
            micMenu.addItem(.separator())
            micMenu.addItem(disabled("↳ recording on the built-in mic "
                + "(the selected device delivered nothing)"))
        }
        micItem.submenu = micMenu
        menu.addItem(micItem)
        cost.mic = Date().timeIntervalSince(micStart) * 1000

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
