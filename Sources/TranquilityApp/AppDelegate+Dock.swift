import AppKit
import TranquilityCore

/// The Dock tile: there while Tranquility Base is open, and nothing decides
/// otherwise.
///
/// Ruled 15 Sep 2026, replacing two days of rules that tried to be clever.
/// The status item is the app's only other door, and macOS drops status
/// items silently when the menu bar is full: on Gary Marx's first run the
/// popover floated under a bar that had no room for the icon. There is no
/// public API to pin an item, to ask whether it is drawn, or to find it once
/// it is not, so every recovery a guide can offer presupposes the icon is
/// visible. The 14 Sep rule showed a tile until the icon was clicked once
/// and then hid it for good; the next morning Robert's own tile was gone.
/// A per-launch rule was drafted and rejected the same hour: "I think that's
/// going to be confusing, whether the dock tile is there or not. Just show
/// the dock tile, it doesn't hurt. It's a lot simpler."
///
/// So: a tile while the app runs. A click on it brings the grid forward.
/// The Dock menu carries the status item's own items, and macOS adds its
/// Hide and Quit under them; Hide is mapped to the panel's own hide, so it
/// does what the word says and does not park the app in a state where an
/// arriving turn cannot surface the panel.
///
/// One writer for the activation policy: this. Onboarding used to set it
/// twice on its own; it no longer touches it.
extension AppDelegate {

    /// Wear the tile. Called once at launch; idempotent after that.
    func showDockTile(because reason: String) {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        Permissions.log("dock: tile shown (\(reason))")
        Track.record("dock_presence", ["shown": true, "reason": Track.token(from: reason)])
        // The system's Hide (Dock menu, ⌘H) hides every window and the panel
        // with it, and a hidden app's panel cannot be ordered front by an
        // ambient turn until the app is unhidden. Unhide at once and hide the
        // PANEL instead, which is what the person meant.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Without activation: `unhide(_:)` would make this app active
                // and put its menu bar over whatever the person was in.
                NSApp.unhideWithoutActivation()
                guard let self else { return }
                Track.record("dock_clicked", ["button": "right", "result": "hide"])
                if self.hud.isOnScreen {
                    if self.hud.canSurfaceAmbiently { self.hud.hide() } else { self.hud.dismiss() }
                }
                Permissions.log("dock: Hide mapped to the panel")
            }
        }
    }

    /// A click on the tile: the grid, exactly as a click on the status item.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        Track.record("dock_clicked", ["button": "left",
                                      "panel_was_on_screen": .bool(hud.isOnScreen)])
        showPanel()
        return false
    }

    /// A right-click on the tile: the status item's menu, the same items in
    /// the same order (ruled 14 Sep 2026). A copy, because the status item
    /// attaches and detaches the original around its own click. macOS
    /// appends Hide and Quit itself.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        rebuildMenu()
        Track.record("dock_clicked", ["button": "right", "result": "menu"])
        return statusMenu?.copy() as? NSMenu
    }
}
