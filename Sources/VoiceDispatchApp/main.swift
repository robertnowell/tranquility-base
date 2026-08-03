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
    private var permissionTimer: Timer?

    private var lastStatusLine = "starting…"
    private var isBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◌"
        rebuildMenu()

        do {
            let store = try QueueStore()
            self.store = store
            let report = try store.reconcileOnBoot()
            if !report.needsDeliveryCheck.isEmpty {
                lastStatusLine = "\(report.needsDeliveryCheck.count) reply/replies need checking"
            }
        } catch {
            lastStatusLine = "queue unavailable: \(error)"
        }

        hotkey = HotkeyMonitor { [weak self] transition in
            // The tap callback runs on the main run loop, but hop explicitly so the
            // compiler agrees and so this stays correct if the tap ever moves.
            Task { @MainActor in self?.handle(transition) }
        }

        startPermissionPolling()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
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

    private func refresh() {
        if !hotkey.isRunning { _ = hotkey.start() }
        rebuildMenu()
        updateTitle()
    }

    private var micGranted: Bool { Recorder.microphoneAuthorized() }
    private var hotkeyWorking: Bool { hotkey?.isRunning ?? false }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        if isBusy { button.title = "●" }
        else if !micGranted || !hotkeyWorking { button.title = "◌!" }
        else { button.title = "◌" }
    }

    // MARK: - Push to talk

    private func handle(_ transition: HotkeyMonitor.Transition) {
        switch transition {
        case .pressed:
            guard micGranted, !recorder.isRecording else { return }
            do {
                try recorder.start()
                isBusy = true
                lastStatusLine = "listening…"
                updateTitle()
            } catch {
                lastStatusLine = "mic failed: \(error)"
            }
        case .released:
            guard recorder.isRecording else { return }
            let captured = try? recorder.stop()
            isBusy = false
            updateTitle()
            guard let captured else {
                lastStatusLine = "nothing recorded"
                rebuildMenu()
                return
            }
            lastStatusLine = "transcribing \(captured.count / 32000)s…"
            rebuildMenu()
            transcribe(captured)
        }
    }

    private func transcribe(_ pcm: Data) {
        guard let store else { return }
        Task { @MainActor in
            do {
                // Audio hits disk inside here, before any network call.
                let utterance = try await store.captureAndTranscribe(pcm16: pcm, sampleRate: 16000)
                switch utterance.status {
                case .transcribed:
                    lastStatusLine = "heard: \(utterance.transcriptText ?? "")"
                case .transcriptionFailed:
                    lastStatusLine = "transcription failed — audio kept, retry from the menu"
                default:
                    lastStatusLine = "utterance \(utterance.status.rawValue)"
                }
            } catch {
                lastStatusLine = "capture failed: \(error)"
            }
            rebuildMenu()
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(disabled(lastStatusLine))
        menu.addItem(.separator())

        menu.addItem(disabled("Hold ⌃⌥ to reply"))
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
