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
