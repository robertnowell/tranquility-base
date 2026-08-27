import AppKit
import TranquilityCore

/// One place to type an API key, used by first run and by the menu.
///
/// Two callers, one sheet, deliberately. A key you can only set during
/// onboarding is a key you cannot rotate, and the first thing anyone does with a
/// leaked or expired key is replace it -- at which point "reinstall the app" is
/// not an answer. `tbase set-key` already covered the terminal case; somebody
/// handed a built app has no repo to run it from, which is the whole reason the
/// first-run screen exists and exactly the reason the menu needs it too.
///
/// The sheet never shows an existing key. It says whether one is stored and
/// offers to replace it: displaying a secret to prove it is there is how secrets
/// end up in screen recordings, and the checkmark in the menu already proves it.
@MainActor
enum KeySheet {

    /// Prompt, save, then ask the provider whether it works.
    ///
    /// `onStatus` is called more than once: immediately with "checking", then
    /// again with the verdict. Saving and verifying are separate on purpose --
    /// see `save` below.
    static func prompt(for key: Secrets.Key,
                       onStatus: @escaping @MainActor (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let stored = Secrets.read(key) != nil

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(key.provider) API key"
        alert.informativeText = """
            \(key.purpose.prefix(1).uppercased() + key.purpose.dropFirst()).

            \(stored ? "A key is already stored. Typing a new one replaces it." : "")
            Stored in your login keychain. Nothing is ever read from the \
            environment, so a stale key in a shell profile cannot shadow this one.
            """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        // A door, not a sentence: the answer to "I do not have one" has to be
        // pressable.
        if key.consoleURL != nil { alert.addButton(withTitle: "Get a key") }
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            save(key, value: value, onStatus: onStatus)
        case .alertThirdButtonReturn:
            if let url = key.consoleURL { NSWorkspace.shared.open(url) }
            // Straight back to the field. They left to fetch the thing it asked
            // for; returning them to nothing would mean starting over.
            prompt(for: key, onStatus: onStatus)
        default:
            return
        }
    }

    /// Write it, then check it.
    ///
    /// In that order, and the order is the decision. Verifying first would mean
    /// a valid key typed on a train is refused for being unreachable. So the key
    /// is saved on the user's say-so and the check is advice afterwards: a
    /// rejection is reported loudly and the key is still KEPT, because deleting
    /// somebody's credential on the strength of one HTTP response is a worse
    /// failure than leaving a bad one in place. They can retype it; they cannot
    /// un-delete it.
    private static func save(_ key: Secrets.Key, value: String,
                             onStatus: @escaping @MainActor (String) -> Void) {
        do {
            try Secrets.write(key, value: value)
        } catch {
            // Said out loud, never swallowed: a key that silently failed to save
            // looks exactly like a key that was never typed.
            onStatus("could not save. \(error.localizedDescription)")
            Permissions.log("keys: write failed for \(key.rawValue) -- \(error)")
            return
        }
        onStatus("checking with \(key.provider)...")
        Task.detached {
            let outcome = await KeyCheck.verify(key, value: value)
            await MainActor.run {
                onStatus(outcome.summary)
                // The verdict, never the value.
                Permissions.log("keys: \(key.rawValue) -- \(outcome.summary)")
                if outcome.isBad { announceRejection(key, outcome) }
            }
        }
    }

    /// A rejected key gets an alert, not just a line in a row.
    ///
    /// The row is enough for "working" and for "could not check". A refusal is
    /// different: it is the one verdict that means the thing the user just did
    /// did not take, and the cost of missing it is silence hours later in the
    /// away-channel, where nothing on screen connects the symptom to the cause.
    private static func announceRejection(_ key: Secrets.Key, _ outcome: KeyCheck.Outcome) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(key.provider) did not accept that key"
        alert.informativeText = """
            \(outcome.summary.prefix(1).uppercased() + outcome.summary.dropFirst()).

            It has been saved anyway, so nothing is lost if this was a blip on \
            their side. But as it stands \(key.purpose) will not work.

            Worth checking for a stray space at either end, and that the key came \
            from \(key.provider) rather than one of the other rows.
            """
        alert.addButton(withTitle: "Try again")
        alert.addButton(withTitle: "Leave it")
        if alert.runModal() == .alertFirstButtonReturn {
            prompt(for: key) { _ in }
        }
    }
}
