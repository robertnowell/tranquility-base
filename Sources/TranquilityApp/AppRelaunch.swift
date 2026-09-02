import AppKit

/// Restart the app, from anywhere.
///
/// This existed already and could be reached from exactly one place: the
/// onboarding window, and only once every permission row was either finished or
/// waiting on the relaunch. That gate is right for onboarding, where offering a
/// premature restart argues with the note beside it. It is wrong as the only
/// route, because the state it exists for outlives first run: a permission
/// granted in System Settings while the app is running, a hooks file rewritten,
/// a key rotated. Robert, 1 Sep: "there's no restart app button in the UI. At
/// some point you have all of them granted but one's not recognized because you
/// need to restart."
///
/// So the mechanism moves here and the SETUP tab gets a door onto it, which is
/// the pane you are already in when you find out you need one.
@MainActor
enum AppRelaunch {

    /// The new instance is launched before this one exits and `stop()` runs on
    /// the way out, so the two never overlap on the global hotkey: two live
    /// instances racing for one chord is a failure this app has had before.
    static func restart(reason: String) {
        let url = Bundle.main.bundleURL
        Permissions.log("relaunch: restarting to \(reason)")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        // Without this, the new process's OWN single-instance guard
        // (main.swift's applicationDidFinishLaunching) sees THIS process still
        // alive at its own launch, reads it as an accidental double launch, and
        // refuses outright before showing anything. Found live, 26 Aug: "I
        // clicked restart and the app did not restart, it just closed." The log
        // confirmed it exactly: the new pid logged `launch: REFUSED, instance
        // already running (pid <this one>)`, and this process then terminated a
        // moment later per the completion handler below, leaving nothing
        // running. This restart is a deliberate, sequenced handoff, not the
        // accidental double-launch that guard exists to catch, so it gets the
        // same exemption the self-test path already has.
        config.arguments = ["--allow-second-instance"]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
