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
        statusItem.button?.title = "◌"
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
                // Write the summary before it is asked for. Doing it on demand meant
                // every use opened with a model call you had to sit through.
                try? await coordinator.prepareNext()

                // Reflect arrivals without being asked. The panel only ever redrew
                // on a keypress, so a session finishing while you were looking
                // straight at it changed nothing and the count went stale. Only
                // while idle: speech, a recording, a countdown or a failure notice
                // are conversations in progress and must not be redrawn under.
                let waiting = (try? self.store?.pendingCount()) ?? 0
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
        // Escape does what Dismiss does — but only when the panel is actually up and
        // busy, so it stays inert while you are using Escape for its usual purpose.
        hotkey.onEscape = { [weak self] in
            guard let self, self.hud.isBusyOnScreen else { return }
            self.hud.dismiss()
        }

        hud.onOpenSettings = { [weak self] in self?.openSettings() }
        hud.onOpenWaitingList = { [weak self] in
            guard let self, let waiting = try? self.coordinator?.waiting() else { return }
            self.hud.showWaitingList(waiting ?? [])
        }
        hud.onPickWaiting = { [weak self] id in self?.announceNext(only: id) }
        hud.onLeaveSettings = { [weak self] in
            guard let self else { return }
            self.coordinator?.speech.stop()
            self.hud.showIdle(waiting: (try? self.store?.pendingCount()) ?? 0,
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
            self.isBusy = false
            // Dismiss means the item is done with — not "hide the window and leave
            // it in the queue", which is what made the button meaningless.
            if let eventId = self.hud.currentEventId {
                try? self.coordinator?.dismiss(eventId: eventId)
            }
            self.updateTitle()
            self.rebuildMenu()
        }

        hud.onReply = { [weak self] in
            guard let self, self.micGranted, !self.recorder.isRecording else { return }
            try? self.recorder.start()
            self.isBusy = true
            self.updateTitle()
        }
        hud.onStopReply = { [weak self] in
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
        Secrets.trace = { Permissions.log("secrets: \($0)") }
        Permissions.log("args=\(CommandLine.arguments)")

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
            hud.showIdle(waiting: (try? store?.pendingCount()) ?? 0,
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
                switch outcome {
                case .queued:
                    lastStatusLine = "queued in \(label)"
                    hud.showResult(
                        "In \(label). It's mid-turn, so it sends when that finishes.", ok: true)
                case .dispatched:
                    lastStatusLine = "sent to \(label)"
                    hud.showResult("Sent to \(label).", ok: true)
                case .sessionNotReady(let readiness):
                    hud.showResult(
                        "\(label) isn't accepting input right now (\(readiness)). "
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

        let symbol: String
        if isBusy { symbol = "waveform.circle.fill" }
        else if !micGranted || !hotkeyWorking { symbol = "exclamationmark.bubble" }
        else { symbol = "waveform.circle" }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voice Dispatch")
        image?.isTemplate = true
        button.image = image
        // Fall back to text if the symbol is unavailable, rather than showing nothing.
        if button.image == nil { button.title = isBusy ? "VD●" : "VD" }
        button.toolTip = "Voice Dispatch. Tap ⌃⌥ to hear, hold ⌥ to reply"
    }

    // MARK: - Push to talk

    private func handle(_ transition: HotkeyMonitor.Transition) {
        switch transition {
        case .next:
            // Next means done with this one. Stopping used to revert the item to
            // unread, and being the newest it was handed straight back, so pressing
            // again replayed what you had just skipped and there was no way past it.
            //
            // The trade, stated plainly: a stray press now retires a summary you had
            // not finished. Nothing is deleted, so it survives in the data, and a
            // queue you cannot drain is the worse problem of the two.
            if case .speaking = hud.state, let eventId = hud.currentEventId {
                try? coordinator?.dismiss(eventId: eventId)
                Permissions.log("next: dismissed \(eventId.prefix(8)) and moved on")
            } else if case .paused = hud.state, let eventId = hud.currentEventId {
                try? coordinator?.dismiss(eventId: eventId)
                Permissions.log("next: dismissed \(eventId.prefix(8)) and moved on")
            }
            announceNext()

        case .pauseToggled:
            guard let speech = coordinator?.speech, speech.isSpeaking || speech.isPaused
            else { return }
            speech.togglePause()
            hud.setPaused(speech.isPaused)

        case .replyBegan:
            guard micGranted, !recorder.isRecording else { return }
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
            if let eventId = hud.currentEventId {
                try? coordinator?.markHeard(eventId: eventId)
                repliedToEventId = eventId
            }
            coordinator?.speech.stop()  // never record over playback
            try? recorder.start()
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

        case .replyAborted:
            // The hold turned out to be part of a real shortcut. Drop the audio
            // rather than transcribing whatever happened to be in the room.
            isBusy = false
            hud.recordingEnded()
            recorder.abandon()
            updateTitle()
            hud.showIdle(waiting: (try? store?.pendingCount()) ?? 0,
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

        // Nothing to play: say so and stop. No preparing state, no flash. History
        // counts as something to play, which is the whole point of catching up.
        if eventId == nil, (try? coordinator.nextToAnnounce()) == nil,
           (try? coordinator.nextForCatchUp()) == nil {
            hud.showIdle(waiting: 0,
                         unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
            return
        }

        hud.isSpeakingNow = true
        // Summarizing and fetching the voice take several seconds. Without this the
        // app shows nothing at all for the whole of that and reads as broken.
        hud.showPreparing()
        announceTask = Task { @MainActor in
            // Silence the old one first, then wait for it to actually be over.
            coordinator.speech.stop()
            previous?.cancel()
            _ = await previous?.value

            defer { isAnnouncing = false; hud.isSpeakingNow = false }
            guard !Task.isCancelled else {
                Permissions.log("announce: cancelled before starting")
                return
            }
            isAnnouncing = true
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
                        let live = ClaudeAgentsCLI().sessions()
                            .first { $0.sessionId == announcement.event.sessionId }
                        self.hud.showAnnouncement(
                            isCatchUp: announcement.isCatchUp,
                            topic: announcement.brief.topic,
                            spoken: announcement.spoken.text,
                            sessionId: announcement.event.sessionId,
                            pid: live?.pid,
                            project: announcement.event.projectLabel,
                            cwd: announcement.event.cwd,
                            eventId: announcement.event.id)
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
                    lastStatusLine = "◀ \(announcement.brief.topic)"
                    hud.highlight(upTo: announcement.spoken.text.count)
                case .interrupted(let failure):
                    // The announce task reverts an interrupted item to unread. If the
                    // interruption WAS the reply, re-apply the mark — this runs after
                    // the revert, so ordering is settled rather than raced.
                    if let replied = repliedToEventId {
                        try? coordinator.markHeard(eventId: replied)
                        repliedToEventId = nil
                        lastStatusLine = "replying"
                        return
                    }
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
                                     waiting: (try? store?.pendingCount()) ?? 0,
                         unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
                    }
                case .held(let reason):
                    lastStatusLine = "held: \(reason)"
                    hud.showIdle(note: "Holding. \(reason).",
                                 waiting: (try? store?.pendingCount()) ?? 0,
                         unsentReplies: (try? store?.unsentReplyCount()) ?? 0)
                case .nothingWaiting:
                    Permissions.log("announce: nothingWaiting")
                    lastStatusLine = "nothing waiting"
                    hud.showIdle(waiting: (try? store?.pendingCount()) ?? 0,
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
    private func sendReply(_ pcm: Data) {
        guard let coordinator else { return }
        let mine = replyGeneration
        lastStatusLine = "transcribing…"
        hud.showWorking("Transcribing your reply…")
        rebuildMenu()

        Task { @MainActor in
            do {
                let outcome = try await coordinator.submitReply(pcm16: pcm)

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
                    lastStatusLine = "▶ sent (\(ms)ms): \(text.prefix(48))"
                    hud.showResult("Sent: \(text)", ok: true)
                case .queued(let text, _):
                    lastStatusLine = "▶ queued: \(text.prefix(48))"
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
                    lastStatusLine = "session busy or blocked (\(readiness)), audio kept"
                    hud.showResult("Session isn't ready (\(readiness)). Recording kept. Try again shortly.", ok: false)
                case .transcriptionFailed:
                    lastStatusLine = "couldn't transcribe, audio kept"
                    hud.showResult("Couldn't transcribe that. The audio is saved. Retry from the menu.", ok: false)
                case .dispatchFailed(.verificationTimedOut, _):
                    lastStatusLine = "⚠ unconfirmed. Check the tab before resending"
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
            hud.showIdle(waiting: (try? store?.pendingCount()) ?? 0,
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
           let pid = ClaudeAgentsCLI().sessions().first(where: { $0.sessionId == target.sessionId })?.pid,
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
        hud.showIdle(waiting: (try? store?.pendingCount()) ?? 0,
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

        menu.addItem(disabled("Tap ⌃⌥ hear · hold ⌥ reply · tap ⇧ pause"))
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
        let item = NSMenuItem(title: "\(granted ? "✓" : "✗")  \(title)", action: granted ? nil : action,
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
