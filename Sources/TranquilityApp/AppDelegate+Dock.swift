import AppKit
import TranquilityCore

/// The Dock tile, and when the app wears one.
///
/// Ruled 14 Sep 2026 after Gary Marx's first run, and tightened 15 Sep. The
/// status item is the app's only permanent door, and macOS drops status
/// items silently when the menu bar is full: on his Mac the popover floated
/// under a bar that had no room for the icon, and "it is not in the menu
/// bar" was the plain truth. `autosaveName` keeps a position the user has
/// dragged to, but there is no public API to pin an item, to ask whether it
/// is drawn, or to find it once it is not. A hidden icon cannot be dragged.
///
/// So the Dock tile is the door that is always there when it is needed, and
/// "needed" is decided per LAUNCH, never per install (15 Sep: "let's obsess
/// if it's going to be in the bottom bar when you need it"). The 14 Sep rule
/// hid the tile for ever after one click, and a bar that had room yesterday
/// has none today: a new app, an external display, a notch.
///
/// The tile is shown unless all three hold: the status item has been
/// clicked in THIS launch, which is the only proof it is drawn right now;
/// the panel is not on screen (the Wispr Flow rule: while the UI is up, so
/// is a tile that focuses it); and onboarding is not showing.
///
/// A click on the tile shows the grid; a right-click carries the status
/// item's own menu, so nothing the menu bar offers is lost with the icon.
///
/// One writer for the activation policy. Onboarding sets `.regular` for its
/// own window and `.accessory` when it closes; its `onDone` then runs this,
/// which is why the tile comes straight back on a machine whose menu bar has
/// not been clicked yet.
extension AppDelegate {

    /// Apply the rule. Idempotent; logs and records only a change.
    func refreshDockPresence(because reason: String) {
        let proven = menuBarClickedThisLaunch
        let wanted: NSApplication.ActivationPolicy =
            (proven && !hud.isOnScreen && !onboarding.isShowing) ? .accessory : .regular
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        let shown = wanted == .regular
        Permissions.log("dock: tile \(shown ? "shown" : "hidden") (\(reason); "
            + "menuBarClickedThisLaunch=\(proven) panel=\(hud.isOnScreen) "
            + "onboarding=\(onboarding.isShowing))")
        Track.record("dock_presence", ["shown": .bool(shown), "reason": Track.token(from: reason),
                                       "menu_bar_clicked_this_launch": .bool(proven),
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
