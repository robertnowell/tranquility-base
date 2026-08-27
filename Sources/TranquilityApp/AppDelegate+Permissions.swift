import AppKit
import TranquilityCore

/// AppDelegate's permission-polling half, split out of main.swift (App-lane
/// P7, 24 Aug) for navigability -- main.swift had grown past 4,400 lines
/// mixing launch, permissions, reply, grid, push-to-talk, deep links,
/// session management, the menu, and self-test drills in one file. No
/// behavior changed and no public API moved.
///
/// Polling is how the UI heals itself when the user grants something in
/// System Settings while the menu is open. The hotkey monitor guards
/// against redundant restarts, so calling start() on every tick is safe.

extension AppDelegate {
    // MARK: - Permissions
    //
    // Polling is how the UI heals itself when the user grants something in System
    // Settings while the menu is open. The hotkey monitor guards against redundant
    // restarts, so calling start() on every tick is safe.

    /// Live state for the earcon gate. Read on the main actor at the moment a cue
    /// wants to play, never cached: a snapshot is a thing that goes stale, and the
    /// whole point of the gate is that it reflects RIGHT NOW.
    func earconGate() -> EarconGate {
        EarconGate(
            userIsSpeaking: recorder.isRecording,
            agentIsSpeaking: {
                guard let speech = coordinator?.speech else { return false }
                return speech.isSpeaking || speech.isPaused
            }())
    }

    /// A required permission revoked while the app runs sends it back to
    /// onboarding — but only on evidence, and never on one reading.
    ///
    /// Ruled 26 Aug: "any time there's a missing permission, revert back to the
    /// onboarding screen instead of showing the grid… even if they've been
    /// using it for three months." The launch check already did that. This is
    /// the same rule for a permission pulled mid-session, which is the case
    /// that actually happened and the one the launch check cannot see.
    ///
    /// TWO DELIBERATE CHOICES, both against the obvious implementation.
    ///
    /// It listens for ACTIVATION rather than polling. Apple publishes no
    /// notification for a TCC change, and their own guidance is to re-check
    /// when the app becomes active: a user must leave this app to reach System
    /// Settings, so coming back is the signal. A timer would ask constantly and
    /// still not learn anything sooner.
    ///
    /// And it requires TWO consecutive misses. `AXIsProcessTrusted()` is
    /// documented returning wrong values on Ventura and later while a toggle is
    /// being flipped — Apple's own DTS advice is to probe functionally rather
    /// than trust the boolean — and there is a known bug where checking
    /// Accessibility first corrupts a later Input Monitoring read. A single
    /// false negative is plausible, and acting on one would take a working
    /// panel away mid-sentence. Two readings a beat apart is the cheapest thing
    /// that cannot be fooled by a toggle in motion.
    func startWatchingForRevokedPermissions() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.confirmPermissionsStillHold() }
        }
    }

    /// The second look. Only a miss that survives it counts.
    @MainActor
    private func confirmPermissionsStillHold() {
        guard !Permissions.allActive else { return }
        let firstMiss = Permissions.Kind.allCases
            .filter(\.isRequired).filter { Permissions.state($0) != .active }
        Permissions.log("permissions: \(firstMiss.map(\.title)) read as missing on activation "
            + "— confirming before acting")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Permissions.allActive else {
                Permissions.log("permissions: the miss did not survive a second look — "
                    + "leaving the panel alone")
                return
            }
            let confirmed = Permissions.Kind.allCases
                .filter(\.isRequired).filter { Permissions.state($0) != .active }
            Permissions.log("permissions: \(confirmed.map(\.title)) confirmed missing — "
                + "back to onboarding")
            self.onboarding.show { [weak self] in self?.refresh() }
        }
    }

    func startPermissionPolling() {
        Earcons.clearOldNotifications()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Kick the off-main probe FIRST so its result is available to
                // the next tick's paint, then paint from what we already have.
                self?.refreshWaitingSnapshot()
                self?.refresh()
            }
        }
    }
}
