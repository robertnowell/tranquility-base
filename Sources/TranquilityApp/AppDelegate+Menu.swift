import AppKit
import TranquilityCore

/// AppDelegate's status-item menu -- construction, the voice/input
/// pickers, settings, and the rebuild-cost drill measurement -- split out
/// of main.swift (App-lane P7, 24 Aug); see AppDelegate+Permissions.
/// swift's doc comment for why.

extension AppDelegate {
    // MARK: - Menu

    /// Left-click opens the grid; right-click opens the menu. The grid is the
    /// interface, the menu is the toolbox.
    @objc func statusItemClicked() {
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

    func timedRebuildMenu() -> RebuildCost {
        let t0 = Date()
        rebuildMenu()
        var cost = lastRebuildCost
        cost.total = Date().timeIntervalSince(t0) * 1000
        return cost
    }

    func rebuildMenu() {
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

    func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func permissionRow(title: String, granted: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "\(granted ? StateLegend.Glyph.confirm : StateLegend.Glyph.denied)  \(title)", action: granted ? nil : action,
                              keyEquivalent: "")
        item.target = granted ? nil : self
        item.isEnabled = !granted
        return item
    }

    @objc func showOnboarding() {
        onboarding.show { [weak self] in self?.refresh() }
    }

    @objc func openMicrophoneSettings() {
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

    @objc func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    @objc func retryFailed() {
        guard let store else { return }
        Task { @MainActor in
            let recovered = (try? await store.retryFailedTranscriptions()) ?? []
            lastStatusLine = recovered.isEmpty
                ? "nothing to recover"
                : "recovered \(recovered.count) utterance(s)"
            rebuildMenu()
        }
    }
}
