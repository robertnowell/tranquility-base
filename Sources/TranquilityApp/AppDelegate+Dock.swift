import AppKit
import TranquilityCore

/// The Dock tile, and when the app wears one.
///
/// Ruled 14 Sep 2026 after Gary Marx's first run. The status item is the
/// app's only permanent door, and macOS drops status items silently when the
/// menu bar is full: on his Mac the popover floated under a bar that had no
/// room for the icon, and "it is not in the menu bar" was the plain truth.
/// `autosaveName` keeps a position the user has dragged to, but there is no
/// public API to pin an item to the right or even to ask whether it is drawn,
/// so on a first run the menu bar cannot be relied on at all.
///
/// So the app takes a Dock tile until an agent has ever appeared on its grid,
/// and whenever the panel is on screen: the same rule as Wispr Flow, whose
/// tile is there while its UI is. A click on the tile shows the grid; a
/// right-click carries the status item's own menu, so nothing the menu bar
/// offers is lost with the icon.
///
/// One writer for the activation policy. Onboarding sets `.regular` for its
/// own window and `.accessory` when it closes; its `onDone` then runs this,
/// which is why the tile comes straight back on a machine that still has no
/// agent.
extension AppDelegate {

    /// Apply the rule. Idempotent; logs and records only a change.
    func refreshDockPresence(because reason: String) {
        let wanted: NSApplication.ActivationPolicy =
            (!StatusHUD.everListedAgent || hud.isOnScreen || onboarding.isShowing)
                ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        let shown = wanted == .regular
        Permissions.log("dock: tile \(shown ? "shown" : "hidden") (\(reason); "
            + "everListed=\(StatusHUD.everListedAgent) panel=\(hud.isOnScreen) "
            + "onboarding=\(onboarding.isShowing))")
        Track.record("dock_presence", ["shown": .bool(shown), "reason": Track.token(from: reason),
                                       "ever_listed": .bool(StatusHUD.everListedAgent),
                                       "panel_on_screen": .bool(hud.isOnScreen)])
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
    /// attaches and detaches the original around its own click.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        rebuildMenu()
        Track.record("dock_clicked", ["button": "right", "result": "menu"])
        return statusMenu?.copy() as? NSMenu
    }
}
