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
/// So the app takes a Dock tile until the status item has been clicked once
/// on this install. One click is the only proof there is that the menu bar
/// is reachable, and it is enough (ruled 14 Sep, 21:20: "if you can click
/// the menu bar icon, you know you have access to it, so you do not need the
/// Dock item"). The tile also stays for the onboarding window. A click on
/// the tile shows the grid; a right-click carries the status item's own
/// menu, so nothing the menu bar offers is lost with the icon.
///
/// One writer for the activation policy. Onboarding sets `.regular` for its
/// own window and `.accessory` when it closes; its `onDone` then runs this,
/// which is why the tile comes straight back on a machine whose menu bar has
/// not been clicked yet.
extension AppDelegate {

    /// Whether the status item has ever been clicked on this install. A fact
    /// on disk: the process that learns it is not the one that needs it.
    static var menuBarEverClicked: Bool {
        get { ProductDefaults.shared.bool(forKey: menuBarEverClickedKey) }
        set { ProductDefaults.shared.set(newValue, forKey: menuBarEverClickedKey) }
    }
    private static let menuBarEverClickedKey = "menubar.everClicked"

    /// Apply the rule. Idempotent; logs and records only a change.
    func refreshDockPresence(because reason: String) {
        let wanted: NSApplication.ActivationPolicy =
            (!Self.menuBarEverClicked || onboarding.isShowing) ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        let shown = wanted == .regular
        Permissions.log("dock: tile \(shown ? "shown" : "hidden") (\(reason); "
            + "menuBarClicked=\(Self.menuBarEverClicked) onboarding=\(onboarding.isShowing))")
        Track.record("dock_presence", ["shown": .bool(shown), "reason": Track.token(from: reason),
                                       "menu_bar_ever_clicked": .bool(Self.menuBarEverClicked)])
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
