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
                if let result = try? coordinator.intake(), result.inserted > 0 {
                    self.rebuildMenu()
                }
                // Write the summary before it is asked for. Doing it on demand meant
                // every use opened with a model call you had to sit through.
                try? await coordinator.prepareNext()
            }
        }

        hotkey = HotkeyMonitor { [weak self] transition in
            // The tap callback runs on the main run loop, but hop explicitly so the
            // compiler agrees and so this stays correct if the tap ever moves.
            Task { @MainActor in self?.handle(transition) }
        }

        // The panel can drive a recording itself, so answering never depends on
        // knowing a hotkey that is invisible in the UI.
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

        ElevenLabsSpeechProvider.trace = { Permissions.log("11labs: \($0)") }
        Permissions.log("args=\(CommandLine.arguments)")

        if CommandLine.arguments.contains("--selftest-hud") {
            hud.selfTest()
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
            let waiting = (try? store?.pendingCount()) ?? 0
            hud.showIdle(waiting > 0
                ? "\(waiting) session\(waiting == 1 ? "" : "s") to hear. "
                    + "Tap ⌃⌥ for the most recent, hold ⌃⌥ to reply."
                : "Ready. Tap ⌃⌥ to hear what's waiting, hold ⌃⌥ to reply.")
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
            // System voice deliberately: the network provider would read the
            // keychain, which prompts for a password before the user has granted
            // anything — a confusing first thing to meet.
            await SpeechChain(preferred: nil).speak(SpokenTextSanitizer().sanitize(line))
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
        Task { @MainActor in
            hud.showWorking("Sending to \(label)…")
            do {
                let outcome = try await coordinator.confirmAndSend(utteranceId: utteranceId)
                Permissions.log("confirmAndSend -> \(outcome)")
                switch outcome {
                case .dispatched:
                    lastStatusLine = "sent to \(label)"
                    hud.showResult("Sent to \(label).", ok: true)
                case .sessionNotReady(let readiness):
                    hud.showResult(
                        "\(label) isn't accepting input right now (\(readiness)). "
                        + "Your words are kept — try again in a moment.", ok: false)
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
        button.toolTip = "Voice Dispatch — tap ⌃⌥ to hear, hold to reply"
    }

    // MARK: - Push to talk

    private func handle(_ transition: HotkeyMonitor.Transition) {
        switch transition {
        case .pressed:
            pressStartedAt = Date()
            // Start capturing immediately. If this turns out to be a tap the audio
            // is thrown away — the alternative, waiting to see if it's a hold, would
            // clip the first third of a second off every reply.
            guard micGranted, !recorder.isRecording else { return }
            // Recording starts only once the press outlives the tap threshold.
            // Starting on press meant every tap opened the microphone while also
            // playing the next announcement — it listened to its own voice. Losing
            // the first ~350ms of a hold is the correct trade: people pause before
            // speaking, and a tap must be silent.
            let indicator = DispatchWorkItem { [weak self] in
                guard let self, !self.recorder.isRecording else { return }
                // Never record over playback.
                self.coordinator?.speech.stop()
                try? self.recorder.start()
                self.isBusy = true
                self.updateTitle()
                self.hud.showListening()
            }
            listeningIndicator = indicator
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapThreshold, execute: indicator)

        case .released:
            let held = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            pressStartedAt = nil
            isBusy = false

            listeningIndicator?.cancel()
            listeningIndicator = nil

            if held < Self.tapThreshold {
                recorder.abandon()
                updateTitle()
                // A tap while it is talking — or while an announcement is still being
                // prepared — means "stop", not "queue another".
                if isAnnouncing || (coordinator?.speech.isSpeaking ?? false) {
                    coordinator?.speech.stop()
                    isAnnouncing = false
                    hud.showIdle("Stopped. Tap ⌃⌥ again for the next one.")
                    rebuildMenu()
                    return
                }
                announceNext()
                return
            }

            guard let captured = try? recorder.stop() else {
                updateTitle()
                lastStatusLine = "nothing recorded"
                rebuildMenu()
                return
            }
            updateTitle()
            sendReply(captured)
        }
    }

    /// Tap: play the next waiting update, then that session becomes the reply target.
    private func announceNext() {
        guard let coordinator, !isAnnouncing else { return }
        isAnnouncing = true
        // Summarizing and fetching the voice take several seconds. Without this the
        // app shows nothing at all for the whole of that and reads as broken.
        hud.showPreparing()
        Task { @MainActor in
            defer { isAnnouncing = false }
            do {
                // A tap is an explicit request to hear something, so the
                // interruptibility gate does not apply — you cannot interrupt
                // someone who just asked.
                switch try await coordinator.announceNext(
                    ignoringGate: true,
                    onWillSpeak: { [weak self] announcement in
                        // Render BEFORE the audio starts. Showing it afterwards is
                        // useless — you have already heard the whole thing by then.
                        guard let self else { return }
                        let live = ClaudeAgentsCLI().sessions()
                            .first { $0.sessionId == announcement.event.sessionId }
                        self.hud.showAnnouncement(
                            topic: announcement.brief.topic,
                            spoken: announcement.spoken.text,
                            sessionId: announcement.event.sessionId,
                            pid: live?.pid,
                            project: announcement.event.projectLabel,
                            cwd: announcement.event.cwd)
                    },
                    onWord: { [weak self] range in
                        Task { @MainActor in self?.hud.highlight(upTo: range.upperBound) }
                    }
                ) {
                case .spoke(let announcement):
                    lastStatusLine = "◀ \(announcement.brief.topic)"
                    hud.highlight(upTo: announcement.spoken.text.count)
                case .held(let reason):
                    lastStatusLine = "held: \(reason)"
                    hud.showIdle("Holding — \(reason)")
                case .nothingWaiting:
                    lastStatusLine = "nothing waiting"
                    hud.showIdle("Nothing waiting. Sessions will queue up here as they finish.")
                }
            } catch {
                lastStatusLine = "announce failed: \(error)"
            }
            rebuildMenu()
        }
    }

    /// Hold: transcribe and route the reply back to whichever session last spoke.
    private func sendReply(_ pcm: Data) {
        guard let coordinator else { return }
        lastStatusLine = "transcribing…"
        hud.showWorking("Transcribing your reply…")
        rebuildMenu()

        Task { @MainActor in
            do {
                switch try await coordinator.submitReply(pcm16: pcm) {
                case .dispatched(let text, let ms, _):
                    lastStatusLine = "▶ sent (\(ms)ms): \(text.prefix(48))"
                    hud.showResult("Sent: \(text)", ok: true)
                case .noTarget:
                    lastStatusLine = "nothing to reply to — tap to hear one first"
                    hud.showResult("Nothing to reply to yet — tap ⌃⌥ to hear one first.", ok: false)
                case .readyToSend(let utteranceId, let text, let label, _):
                    // Sending is the default. The window exists to stop it, not to
                    // permit it — approving every correct transcript is a toll.
                    lastStatusLine = "sending to \(label)…"
                    hud.showPendingSend(
                        text: text, label: label, seconds: 4,
                        send: { [weak self] in self?.send(utteranceId: utteranceId, label: label) },
                        cancel: { [weak self] in
                            guard let self else { return }
                            try? self.coordinator?.cancelSend(utteranceId: utteranceId)
                            // Straight back to listening: you stopped it because the
                            // words were wrong, so the next thing you want is to say
                            // them again, not to hunt for a button.
                            self.hud.showListening()
                            if self.micGranted, !self.recorder.isRecording {
                                try? self.recorder.start()
                                self.isBusy = true
                                self.updateTitle()
                            }
                        })
                case .sessionNotReady(let readiness):
                    lastStatusLine = "session busy or blocked (\(readiness)) — audio kept"
                    hud.showResult("Session isn't ready (\(readiness)). Recording kept — try again shortly.", ok: false)
                case .transcriptionFailed:
                    lastStatusLine = "couldn't transcribe — audio kept, retry from the menu"
                    hud.showResult("Couldn't transcribe that. The audio is saved — retry from the menu.", ok: false)
                case .dispatchFailed(.verificationTimedOut, _):
                    lastStatusLine = "⚠ unconfirmed — check the tab before resending"
                    hud.showResult(
                        "Sent, but never confirmed. It may or may not have landed — "
                        + "check the tab before resending.", ok: false)
                case .dispatchFailed(let failure, _):
                    lastStatusLine = "send failed: \(failure) — audio kept"
                }
            } catch {
                lastStatusLine = "reply failed: \(error)"
            }
            rebuildMenu()
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled(lastStatusLine))
        menu.addItem(.separator())

        menu.addItem(disabled("Tap ⌃⌥ to hear · hold to reply"))
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
