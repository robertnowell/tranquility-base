import AppKit

/// The reason Command-V does nothing in this app.
///
/// Tranquility Base is an `LSUIElement`: no dock icon, no menu bar, and,
/// because nobody ever built one, `NSApp.mainMenu` is nil. That reads as a
/// cosmetic absence and is not one. AppKit routes the standard editing key
/// equivalents THROUGH the main menu: `NSApplication.sendEvent` offers a
/// key-down to `mainMenu.performKeyEquivalent` before the responder chain gets
/// it, and with no menu there is nothing to match Command-V against. So every
/// text field in the app has been paste-proof since the first one shipped, and
/// the field where it costs the most is the one you meet first.
///
/// Robert, 1 Sep, on the API key sheet: "the input window, you can't
/// Command-V into that, you have to right-click paste, which is annoying."
/// Right-click worked because a text field builds its own context menu with no
/// help from the app; the keyboard had nothing to go through.
///
/// A menu an accessory app never displays still answers key equivalents. That
/// is the whole fix, and it is app-wide rather than sheet-wide on purpose: the
/// key sheet was where it was noticed, and the agent LAUNCH and DIRECTORY
/// fields in Settings, and the past-agents filter, were all equally unable to
/// take a paste.
enum EditMenu {

    /// Build it once, at launch, before any window can take the keyboard.
    static func install() {
        guard NSApp.mainMenu == nil else { return }

        let edit = NSMenu(title: "Edit")
        // The standard selectors, sent to nil so they travel the responder
        // chain and land on whatever field is first responder. Naming a target
        // here would bind the menu to one field, which is the bug in a
        // different shape.
        let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for (title, action, key, modifiers) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }

        // Command-W and Command-Q, for the same reason. The onboarding window
        // is `.titled` and closable, so it has a close box; a window you can
        // only leave with the mouse is the same class of omission as a field
        // you can only paste into with the mouse.
        let window = NSMenu(title: "Window")
        let close = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)),
                               keyEquivalent: "w")
        window.addItem(close)

        let app = NSMenu(title: "Tranquility Base")
        app.addItem(NSMenuItem(title: "Quit Tranquility Base",
                               action: #selector(NSApplication.terminate(_:)),
                               keyEquivalent: "q"))

        let main = NSMenu()
        for submenu in [app, edit, window] {
            let holder = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            main.addItem(holder)
        }
        NSApp.mainMenu = main
    }
}
