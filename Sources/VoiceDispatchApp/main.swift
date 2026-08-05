import AppKit
import Foundation
import VoiceDispatchCore

/// Menu-bar-only app (`LSUIElement`). No dock icon, no main window.
///
/// This is the shell the loop lives in: it owns the hotkey tap, the microphone, and
/// the permission state that neither can work without. Everything it coordinates —
/// the queue, the summarizer, dispatch — is in VoiceDispatchCore and is exercised by
/// `vdctl` without any of this.
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
    private var pressStartedAt: Date?
    private var listeningIndicator: DispatchWorkItem?
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
    /// No session to answer? The mic still works: the transcript goes to the
    /// clipboard instead of a terminal. A voice tool that refuses to listen just
    /// because nothing is waiting is leaving its best hardware idle.
    private var dictationMode = false
    /// Hands-free listening: started by a double-tap of ⌥, ended by a single tap.
    /// Distinct from the push-to-talk flag because releasing a key you are not
    /// holding must not end anything.
    private var handsFreeListening = false
    private var lastOptionTapAt: Date?
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
    /// Incremented every time a reply gesture starts.
    ///
    /// Cancelling the countdown only covers the four seconds it is on screen.
    /// Speaking again during transcription — the gap between letting go and the
    /// window appearing — left the earlier reply in flight with nothing watching
    /// it, so it surfaced and sent anyway. A counter covers both windows and any
    /// future one, because it asks "is this still the reply the user wants" rather
    /// than "is a particular UI state showing".
    private var replyGeneration = 0
    /// What the idle panel is currently displaying, so it is redrawn on change
    /// rather than on every poll.
    private var lastShownCounts: (Int, Int) = (-1, -1)
    /// Consulted only for unprompted surfacing. A keypress is never gated: you
    /// cannot interrupt someone who has just asked for something.
    private let gate = InterruptGate(minimumIdleSeconds: 0)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = StateLegend.menuBarPlaceholder
        rebuildMenu()

        do {
            let store = try QueueStore()
            self.store = store
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
                let waiting = self.waitingNow()
                let unsent = (try? self.store?.unsentReplyCount()) ?? 0
                // Only on a change. Redrawing every tick repositions the panel and
                // resets its layout for no reason, which reads as flicker on a
                // window that is meant to sit still.
                let arrived = turnArrived && waiting > 0
                if self.hud.canSurfaceAmbiently,
                   arrived || (waiting, unsent) != self.lastShownCounts {
                    self.lastShownCounts = (waiting, unsent)
                    if arrived {
                        self.surfaceArrival(waiting: waiting, unsent: unsent)
                    } else if self.hud.isOnScreen {
                        // Count fell (something was heard or dismissed). Keep the
                        // panel truthful, but never raise it for a decrease: a
                        // window appearing to tell you there is less to do is noise.
                        self.hud.showIdle(waiting: waiting, unsentReplies: unsent)
                    }
                }
            }
        }

        hotkey = HotkeyMonitor { [weak self] transition in
            if case .pauseToggled = transition {
                Task { @MainActor in
                    guard let self, let speech = self.coordinator?.speech,
                          speech.isSpeaking || speech.isPaused else { return }
                    speech.togglePause()
                    self.hud.setPaused(speech.isPaused)
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
        hud.onOpenWaitingList = { [weak self] in
            guard let self, let waiting = try? self.coordinator?.waiting() else { return }
            self.hud.showWaitingList((waiting ?? []).map {
                (id: $0.sessionId, label: $0.projectLabel,
                 topic: $0.summaryText?.split(separator: ".").first.map(String.init)
                     ?? $0.lastAssistantMessage?.prefix(60).description ?? "waiting")
            })
        }
        hud.onPickWaiting = { [weak self] id in self?.announceNext(only: id) }
        hud.onLeaveSettings = { [weak self] in
            guard let self else { return }
            self.coordinator?.speech.stop()
            self.hud.showIdle(waiting: self.waitingNow(),
                              unsentReplies: (try? self.store?.unsentReplyCount()) ?? 0)
        }

        hud.onChooseVoice = { [weak self] id in
            guard let self else { return }
            VoiceCatalog.selectedVoiceId = id
            self.rebuildMenu()
            // Silence the last preview first. Auditioning voices means switching
            // fast, and without this each pick layered onto the one before it,
            // which is the one thing this app must never do.
            self.coordinator?.speech.stop()
            // Play the real thing. A stock sample tells you how a voice handles a
            // stock sentence; what you actually want to know is how it handles YOUR
            // summaries, which are dense, full of proper nouns, and end in a question.
            Task { @MainActor in
                guard let chain = self.coordinator?.speech else { return }
                _ = await chain.speak(SpokenTextSanitizer().sanitize(self.previewText()))
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

        hud.onReply = { [weak self] in
            guard let self, self.micGranted, !self.recorder.isRecording else { return }
            if let ctx = self.resolveReplyContext() {
                self.hud.adoptTarget(sessionId: ctx.sessionId, pid: ctx.pid,
                                     label: ctx.label, cwd: ctx.cwd)
                self.recordingTarget = ctx.sessionId
            } else {
                self.dictationMode = true
                self.hud.dictationDestination = FocusedInput.focusedEditableApp()
                    .map { StateLegend.destination($0) } ?? StateLegend.clipboardDestination
            }
            try? self.recorder.start()
            self.isBusy = true
            self.updateTitle()
        }
        hud.onStopReply = { [weak self] in
            self?.handsFreeListening = false
            guard let self, let captured = try? self.recorder.stop() else {
                self?.hud.recordingEnded()
                return
            }
            self.isBusy = false
            self.updateTitle()
            self.hud.recordingEnded()
            self.sendReply(captured)
        }

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

        // Drive the real speech chain end to end so the highlight can be checked
        // from code instead of from a screenshot.
        if CommandLine.arguments.contains("--selftest-speak") {
            let text = SpokenTextSanitizer().sanitize(
                "Testing the word highlight. The second sentence should light up after the first.")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                hud.showAnnouncement(topic: "Highlight check", spoken: text.text,
                                     sessionId: "selftest", pid: nil,
                                     project: "voice-dispatch", cwd: nil)
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
            hud.showIdle(waiting: waitingNow(),
                         unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
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
        let line = missing.isEmpty
            ? "Voice dispatch is running. Tap control option to hear what's waiting."
            : "Voice dispatch is running. Setting up permissions now."

        Task { @MainActor in
            // The good voice or none at all.
            //
            // This used the system voice deliberately, because the network provider
            // once read the keychain and would prompt for a password before the user
            // had granted anything. Secrets moved to a file months of debugging ago,
            // so that reason is gone — but the robot voice stayed, and it was the
            // first thing you heard every launch.
            //
            // A greeting is not worth a bad impression. If the good voice is
            // unavailable the app simply starts quietly; the panel still appears,
            // which is the part that matters.
            // Cached per voice: the same sentence every launch is not worth
            // re-synthesizing, or worth a network round trip in front of the first
            // thing the app does.
            await GreetingCache.speak(line)
            if !Permissions.allGranted {
                onboarding.show { [weak self] in self?.refresh() }
            }
        }
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
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Dispatch a transcript whose undo window has closed, and say exactly what
    /// happened. "Couldn't send it" hid a `try?` that swallowed the real outcome —
    /// including the one case that matters most, where the text may have landed but
    /// the read-back could not confirm it.
    private func send(utteranceId: String, label: String) {
        guard let coordinator else { return }
        let mine = replyGeneration
        Task { @MainActor in
            guard mine == replyGeneration else {
                // Superseded between the timer firing and this running.
                try? coordinator.cancelSend(utteranceId: utteranceId)
                return
            }
            hud.showWorking("Sending to \(label)…")
            do {
                let outcome = try await coordinator.confirmAndSend(utteranceId: utteranceId)
                Permissions.log("confirmAndSend -> \(outcome)")
                // The confirm round-trip can outlive the user's attention: they may
                // already be listening to the NEXT session when this lands. A
                // success receipt must not stomp the live panel — that is exactly
                // how a stale 6s auto-hide took the window down mid-speech.
                // Failures always surface: they are the case with work left to do.
                let somethingElseOnStage: Bool = {
                    switch hud.state {
                    case .speaking, .preparing, .listening, .pendingSend, .paused: return true
                    default: return false
                    }
                }()
                switch outcome {
                case .queued:
                    lastStatusLine = "queued in \(label)"
                    if somethingElseOnStage {
                        Permissions.log("send: queued in \(label) (quiet; stage busy)")
                    } else {
                        hud.showResult(
                            "In \(label), sends when its turn finishes. ⌥ again to follow up.",
                            ok: true)
                    }
                case .dispatched:
                    lastStatusLine = "sent to \(label)"
                    if somethingElseOnStage {
                        Permissions.log("send: confirmed to \(label) (quiet; stage busy)")
                    } else {
                        hud.showResult("Sent to \(label). ⌥ again to follow up, ⌃⌥ for the next.",
                                       ok: true)
                    }
                case .sessionNotReady(let readiness):
                    // Sanctioned change (b): the actual condition in plain words,
                    // not the enum case's name. Mapping documented in
                    // StateLegend.plainWords(for:).
                    hud.showResult(
                        "\(label) can't take this yet — \(StateLegend.plainWords(for: readiness)). "
                        + "Your words are kept. Try again in a moment.", ok: false)
                case .dispatchFailed(.verificationTimedOut, _):
                    hud.showResult(
                        "Typed it into \(label), but couldn't confirm it landed. "
                        + "Check the tab before repeating yourself.", ok: false)
                case .dispatchFailed(let failure, _):
                    hud.showResult("Couldn't type into \(label): \(failure). "
                                   + "Your words are kept.", ok: false)
                case .noTarget:
                    hud.showResult("That reply lost its session. Your words are kept.", ok: false)
                default:
                    hud.showResult("Unexpected result: \(outcome). Your words are kept.", ok: false)
                }
            } catch {
                Permissions.log("confirmAndSend threw: \(error)")
                hud.showResult("Send failed: \(error). Your words are kept.", ok: false)
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
        var resolved: (sessionId: String, label: String, cwd: String?)?
        if let conversation = activeConversation {
            // The session on screen or just replied to — your attention, which
            // outranks anything derived from cursors.
            resolved = conversation
        } else if let target = try? coordinator?.replyTarget() ?? nil {
            resolved = (target.sessionId, target.projectLabel, target.cwd)
        }
        guard let resolved else { return nil }
        let live = (ClaudeAgentsCLI().sessions() ?? [])
            .first(where: { $0.sessionId == resolved.sessionId })
        // Prefer the live session name ("promotions-49") over the bare project
        // label ("promotions"): several sessions share a label, and the name is
        // the same string Claude Code shows, so it is checkable against the tab.
        return (resolved.sessionId, live?.pid, live?.name ?? resolved.label, resolved.cwd)
    }

    /// The badge, from the same predicate a keypress uses.
    private func waitingNow() -> Int { (try? coordinator?.waitingCount()) ?? 0 }

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
        button.title = ""

        // Three states, mapped in the same legend the panel reads from.
        let state: StateLegend.MenuBarState
        if isBusy { state = .busy }
        else if !micGranted || !hotkeyWorking { state = .permissionWarning }
        else { state = .normal }
        let appearance = StateLegend.menuBar(state)

        let image = NSImage(systemSymbolName: appearance.symbol,
                            accessibilityDescription: "Voice Dispatch")
        image?.isTemplate = true
        button.image = image
        // Fall back to text if the symbol is unavailable, rather than showing nothing.
        if button.image == nil { button.title = appearance.textFallback }
        button.toolTip = "Voice Dispatch. Tap ⌃⌥ to hear, hold ⌥ to reply"
    }

    // MARK: - Push to talk

    private func handle(_ transition: HotkeyMonitor.Transition) {
        // Acknowledge before acting. Every recognized gesture pulses the panel
        // border, so a registered press is visibly different from a missed one.
        switch transition {
        case .next, .pauseToggled, .replyBegan, .dismiss:
            hud.flashAcknowledge()
        case .optionTapped, .replyEnded, .replyAborted, .controlDoubleTapped:
            break  // optionTapped flashes only when it becomes an action, below
        }
        switch transition {
        case .next:
            // Open issue #6, wired at last: ⌃⌥ while the microphone is open would
            // start an announcement into a live mic — it would record itself.
            // The question is answered by the state, in one place, for every path
            // that opens the mic through `.listening`.
            guard !hud.isCapturingAudio else {
                Permissions.log("next: ignored, microphone is open")
                return
            }
            // During the undo window, moving on means "send it and move on": the
            // countdown fast-forwards instead of racing the next announcement.
            if hud.commitPendingSendNow() {
                Permissions.log("next: committed the pending send before advancing")
            }
            activeConversation = nil   // moving on is the explicit end of a conversation
            // Next means done with this one. Stopping used to revert the item to
            // unread, and being the newest it was handed straight back, so pressing
            // again replayed what you had just skipped and there was no way past it.
            //
            // The trade, stated plainly: a stray press now retires a summary you had
            // not finished. Nothing is deleted, so it survives in the data, and a
            // queue you cannot drain is the worse problem of the two.
            // Next means done with this one. Dismissal is a watermark, so a later
            // turn from the same session revives it without anything being undone.
            switch hud.state {
            case .speaking, .paused:
                if let sessionId = hud.currentEventId { dismissCurrent(sessionId) }
            default: break
            }
            announceNext()

        case .dismiss:
            // Same action as the Dismiss button; a chord because Escape leaks ESC
            // into the focused terminal and interrupts the Claude session there.
            if hud.isBusyOnScreen || hud.isOnScreen { hud.dismiss() }

        case .optionTapped:
            // While locked, one tap sends — the mirror of releasing the held key.
            if handsFreeListening {
                hud.flashAcknowledge()
                handsFreeListening = false
                handle(.replyEnded)
                return
            }
            // Two quick taps lock hands-free listening: Wispr's pattern, for
            // replies too long to spend holding a key. Everything downstream is the
            // ordinary reply path — same meter, same undo window, same routing.
            if let last = lastOptionTapAt, Date().timeIntervalSince(last) < 0.45 {
                lastOptionTapAt = nil
                guard micGranted, !recorder.isRecording else { return }
                hud.flashAcknowledge()
                handsFreeListening = true
                if let ctx = resolveReplyContext() {
                    hud.adoptTarget(sessionId: ctx.sessionId, pid: ctx.pid,
                                    label: ctx.label, cwd: ctx.cwd)
                    recordingTarget = ctx.sessionId
                } else {
                    dictationMode = true
                hud.dictationDestination = FocusedInput.focusedEditableApp()
                    .map { StateLegend.destination($0) } ?? StateLegend.clipboardDestination
                }
                if let sessionId = hud.currentEventId,
                   let latest = try? coordinator?.waiting().first(where: { $0.sessionId == sessionId }) {
                    try? coordinator?.markHeard(sessionId: sessionId, through: latest.latestId)
                }
                coordinator?.speech.stop()
                do {
                    try recorder.start()
                } catch {
                    Permissions.log("mic: start failed (hands-free): \(error)")
                    handsFreeListening = false
                    dictationMode = false
                    recordingTarget = nil
                    hud.showResult("Couldn't open the microphone — try again. (\(error))",
                                   ok: false)
                    return
                }
                isBusy = true
                updateTitle()
                hud.showListening(level: { [weak self] in self?.recorder.level ?? 0 },
                                  handsFree: true)
                Permissions.log("hands-free: listening locked")
            } else {
                lastOptionTapAt = Date()
            }

        case .pauseToggled:
            guard let speech = coordinator?.speech, speech.isSpeaking || speech.isPaused
            else { return }
            speech.togglePause()
            hud.setPaused(speech.isPaused)

        case .controlDoubleTapped:
            // WS-A will pull one level deeper on this gesture. Plumbing only for now:
            // no spoken behavior, no visual behavior, just the log line.
            Permissions.log("depth-1 pull: not yet implemented — WS-A")

        case .replyBegan:
            guard micGranted, !recorder.isRecording else { return }
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
            // Replying to what is currently playing is the normal case, not an edge
            // one — you answer as soon as you have heard enough. Mark it heard
            // BEFORE stopping, because stopping reverts it to unread and that is
            // what threw the reply away.
            // Answering it counts as hearing it: you replied, so it is dealt with.
            if let sessionId = hud.currentEventId,
               let latest = try? coordinator?.waiting().first(where: { $0.sessionId == sessionId }) {
                try? coordinator?.markHeard(sessionId: sessionId, through: latest.latestId)
            }
            coordinator?.speech.stop()  // never record over playback
            do {
                try recorder.start()
            } catch {
                // Route changes make this genuinely transient — say so and stop,
                // rather than showing a Listening pill over a dead microphone.
                Permissions.log("mic: start failed: \(error)")
                dictationMode = false
                recordingTarget = nil
                hud.showResult("Couldn't open the microphone — try again. (\(error))",
                               ok: false)
                return
            }
            isBusy = true
            updateTitle()
            hud.showListening(level: { [weak self] in self?.recorder.level ?? 0 })

        case .replyEnded:
            isBusy = false
            hud.recordingEnded()
            guard let captured = try? recorder.stop() else {
                updateTitle()
                lastStatusLine = "nothing recorded"
                rebuildMenu()
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
            hud.showIdle(waiting: waitingNow(),
                         unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
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
        let previous = announceTask
        // Summarizing and fetching the voice take several seconds. Without this the
        // app shows nothing at all for the whole of that and reads as broken.
        hud.showPreparing()
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
                hud.showIdle(waiting: 0,
                             unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
                return
            }
            Permissions.log("announce: starting")
            do {
                // A tap is an explicit request to hear something, so the
                // interruptibility gate does not apply — you cannot interrupt
                // someone who just asked.
                switch try await coordinator.announceNext(
                    only: eventId,
                    ignoringGate: true,
                    onWillSpeak: { [weak self] announcement in
                        // Render BEFORE the audio starts. Showing it afterwards is
                        // useless — you have already heard the whole thing by then.
                        guard let self else { return }
                        let live = (ClaudeAgentsCLI().sessions() ?? [])
                            .first { $0.sessionId == announcement.event.sessionId }
                        self.activeConversation = (
                            announcement.event.sessionId,
                            announcement.event.projectLabel,
                            announcement.event.cwd)
                        self.hud.showAnnouncement(
                            topic: announcement.brief.topic,
                            spoken: announcement.spoken.text,
                            sessionId: announcement.event.sessionId,
                            pid: live?.pid,
                            project: announcement.event.projectLabel,
                            cwd: announcement.event.cwd,
                            eventId: announcement.event.sessionId)
                    },
                    onWord: { [weak self] range in
                        Task { @MainActor in self?.hud.highlight(upTo: range.upperBound) }
                    }
                ) {
                case .spoke(let announcement):
                    Permissions.log("announce: spoke via \(announcement.via)")
                    if let degraded = announcement.degraded {
                        // Heard, but in the plainer voice. Say why, or an outage
                        // reads as the app just sounding worse for no reason.
                        hud.note("Read in the system voice. \(degraded)")
                    }
                    lastStatusLine = "\(StateLegend.Glyph.speaking) \(announcement.brief.topic)"
                    hud.highlight(upTo: announcement.spoken.text.count)
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
                            + "tap ⌃⌥ to hear it again.", ok: false)
                    } else {
                        lastStatusLine = "stopped, still unread"
                        hud.showIdle(note: "Stopped, still unread.",
                                     waiting: waitingNow(),
                         unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
                    }
                case .held(let reason):
                    lastStatusLine = "held: \(reason)"
                    hud.showIdle(note: "Holding. \(reason).",
                                 waiting: waitingNow(),
                         unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
                case .nothingWaiting:
                    Permissions.log("announce: nothingWaiting")
                    lastStatusLine = "nothing waiting"
                    hud.showIdle(waiting: waitingNow(),
                         unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
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

    /// voicedispatch://hear?session=ID   speak that session's summary
    /// voicedispatch://reply?session=ID  open the mic, route the reply there
    /// voicedispatch://show              raise the panel
    ///
    /// This is what lets a local HTML page carry live buttons: an <a href> to a
    /// custom scheme needs no server and no CORS, and the browser confirms before
    /// launching the app, which is the guard against drive-by pages. A reply link
    /// only ever OPENS the microphone with the panel visibly listening — nothing
    /// records silently, and nothing sends without the usual undo window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let action = url.host ?? ""
            let session = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "session" })?.value
            Permissions.log("deeplink: \(action) session=\(session?.prefix(8) ?? "-")")
            hud.flashAcknowledge()

            switch action {
            case "hear":
                announceNext(only: session)
            case "reply":
                guard micGranted, !recorder.isRecording else { break }
                // The page names its session; that is the whole point of the button.
                // Unknown id → refuse to open the mic, never fall back to a guess.
                guard let session,
                      let target = try? store?.waitingSessionsIncludingHeard()
                          .first(where: { $0.sessionId == session }) else {
                    hud.showResult("That page's session isn't in the log. Nothing recorded.",
                                   ok: false)
                    break
                }
                let pid = (ClaudeAgentsCLI().sessions() ?? [])
                    .first(where: { $0.sessionId == session })?.pid
                hud.adoptTarget(sessionId: session, pid: pid,
                                label: target.projectLabel, cwd: target.cwd)
                recordingTarget = session
                activeConversation = (session, target.projectLabel, target.cwd)
                // Hands-free, because no key is held: a single ⌥ tap or the Send
                // button ends it. Without this the recording had no clean ending.
                handsFreeListening = true
                coordinator?.speech.stop()
                try? recorder.start()
                isBusy = true
                updateTitle()
                hud.showListening(level: { [weak self] in self?.recorder.level ?? 0 },
                                  handsFree: true)
            case "show":
                showPanel()
            default:
                Permissions.log("deeplink: unknown action \(action)")
            }
        }
    }

    private func sendReply(_ pcm: Data) {
        guard let coordinator else { return }
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
            hud.showResult("Didn't catch that — too short or too quiet. Nothing sent.",
                           ok: false)
            rebuildMenu()
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
                    let utterance = try await store.captureAndTranscribe(
                        pcm16: pcm, sampleRate: 16_000, chain: RecoveryChain(), eventId: nil)
                    // Cancelled (or replaced) while transcribing: the words must not
                    // be pasted anywhere. The audio row is durable and stays.
                    guard mine == replyGeneration else {
                        Permissions.log("dictation: superseded or cancelled mid-transcription; dropped")
                        return
                    }
                    guard let text = utterance.transcriptText, !text.isEmpty else {
                        hud.showResult("Couldn't transcribe that. Audio kept.", ok: false)
                        return
                    }
                    // Wispr's rule: a focused text field wins; clipboard otherwise.
                    if let app = FocusedInput.focusedEditableApp() {
                        FocusedInput.paste(text)
                        Permissions.log("dictation: typed \(text.count) chars into \(app)")
                        hud.showResult("Typed into \(app).", ok: true)
                    } else {
                        if !FocusedInput.trusted { FocusedInput.requestTrustOnce() }
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                        Permissions.log("dictation: copied \(text.count) chars to clipboard")
                        hud.showResult("Copied to clipboard: \u{201C}\(text.prefix(80))\u{201D}",
                                       ok: true)
                    }
                    rebuildMenu()
                    return
                }
                guard let spokenTo = recordingTarget else {
                    Permissions.log("send: recording has no captured address; refusing")
                    hud.showResult("This recording lost its address. Audio kept; nothing sent.",
                                   ok: false)
                    rebuildMenu()
                    return
                }
                recordingTarget = nil
                let outcome = try await coordinator.submitReply(pcm16: pcm, to: spokenTo)

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
                case .dispatched(let text, let ms, _):
                    lastStatusLine = "\(StateLegend.Glyph.sent) sent (\(ms)ms): \(text.prefix(48))"
                    hud.showResult("Sent: \(text)", ok: true)
                case .queued(let text, _):
                    lastStatusLine = "\(StateLegend.Glyph.sent) queued: \(text.prefix(48))"
                    hud.showResult("Queued: \(text)", ok: true)
                case .noTarget:
                    lastStatusLine = "nothing to reply to yet"
                    hud.showResult("Nothing to reply to yet. Tap ⌃⌥ to hear one first.", ok: false)
                case .readyToSend(let utteranceId, let text, let label, _):
                    // Sending is the default. The window exists to stop it, not to
                    // permit it: approving every correct transcript is a toll.
                    lastStatusLine = "sending to \(label)…"
                    hud.showPendingSend(
                        text: text, label: label, seconds: 4,
                        send: { [weak self] in self?.send(utteranceId: utteranceId, label: label) },
                        cancel: { [weak self] restartListening in
                            guard let self else { return }
                            // The recording is kept, just taken out of the sendable
                            // set — you rejected these words, not the audio.
                            try? self.coordinator?.cancelSend(utteranceId: utteranceId)
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
                    hud.showResult("Can't send yet — \(why). Recording kept. Try again shortly.", ok: false)
                case .transcriptionFailed:
                    lastStatusLine = "couldn't transcribe, audio kept"
                    hud.showResult("Couldn't transcribe that. The audio is saved. Retry from the menu.", ok: false)
                case .dispatchFailed(.verificationTimedOut, _):
                    lastStatusLine = "\(StateLegend.Glyph.needsYou) unconfirmed. Check the tab before resending"
                    hud.showResult(
                        "Sent, but never confirmed. It may or may not have landed. "
                        + "check the tab before resending.", ok: false)
                case .dispatchFailed(let failure, _):
                    lastStatusLine = "send failed: \(failure), audio kept"
                }
            } catch {
                lastStatusLine = "reply failed: \(error)"
            }
            rebuildMenu()
        }
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
            hud.showIdle(waiting: waitingNow(),
                         unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
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
    private func surfaceArrival(waiting: Int, unsent: Int) {
        let decision = gate.evaluate()
        guard decision.allowed else {
            // Held, not dropped. The count is still right the moment the panel is
            // next shown, and nothing was lost by staying quiet.
            Permissions.log("ambient: held (\(decision.reason))")
            return
        }
        if let front = frontmostSessionTty(), let target = try? coordinator?.nextToAnnounce(),
           let pid = (ClaudeAgentsCLI().sessions() ?? []).first(where: { $0.sessionId == target.sessionId })?.pid,
           ProcessProbe.tty(of: pid) == front {
            // You are looking straight at the tab that just finished. Announcing it
            // is telling you something you can already see.
            Permissions.log("ambient: skipped, that session is the frontmost tab")
            return
        }
        Permissions.log("ambient: surfaced for \(waiting) waiting")
        hud.showIdle(waiting: waiting, unsentReplies: unsent)
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
            selected: VoiceCatalog.selectedVoiceId,
            previewNote: "Pick a voice and it reads your most recent summary.")
    }

    @objc private func showPanel() {
        hud.showIdle(waiting: waitingNow(),
                     unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled(lastStatusLine))
        menu.addItem(.separator())

        // A guaranteed way back to the panel. The status icon can end up behind the
        // notch or in the overflow on a crowded menu bar, and then there is no
        // discoverable route to a window that has no Dock icon by design.
        let show = NSMenuItem(title: "Show panel", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

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

        if let store, let pending = try? store.pendingCount(), pending > 0 {
            menu.addItem(disabled("\(pending) waiting"))
        }
        let retry = NSMenuItem(title: "Retry failed transcriptions",
                               action: #selector(retryFailed), keyEquivalent: "")
        retry.target = self
        menu.addItem(retry)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
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
    /// nothing is lost — `vdctl utterances` still has it.
    private func cancelTranscription() {
        replyGeneration += 1
        recordingTarget = nil
        dictationMode = false
        lastStatusLine = "transcription cancelled, audio kept"
        Permissions.log("transcription: cancelled from the panel; audio is kept")
        hud.showIdle(waiting: waitingNow(),
                     unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
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
