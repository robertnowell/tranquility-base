import AppKit
import Foundation
import TranquilityCore
import UserNotifications

/// The sound an agent makes when it comes back.
///
/// Replaces the spoken callsign, ruled 10 Aug: "kill the callsign announcement…
/// if you're on Do Not Disturb, agents return silently. If you're not, they give
/// a little sound indicator that something's come back. That's Pavlovian, and it
/// tells you there's something ready for you to work."
///
/// ## Why this goes through the notification centre rather than `NSSound`
///
/// The ruling's condition is Do Not Disturb, and **the app cannot read Focus
/// state.** `~/Library/DoNotDisturb/DB/` is TCC-protected — measured 10 Aug,
/// `PermissionError` without Full Disk Access — and the legacy
/// `com.apple.notificationcenterui doNotDisturb` default has returned nothing
/// since Monterey. There is no public API. Asking for Full Disk Access so a
/// menu-bar app can decide whether to play a chime is not a trade worth making.
///
/// `UNUserNotificationCenter` inverts the problem: we do not ask whether we may
/// make a sound, we hand the system a request and let it decide. Focus, Do Not
/// Disturb, per-app sound settings, scheduled summaries and the user's own
/// mute switch are all applied by macOS, correctly, for free — and the user gets
/// native controls in System Settings instead of a preference we would have to
/// build, explain and keep working.
///
/// The cost, stated plainly because it is real: one authorisation prompt, and an
/// entry in Notification Center per arrival. `.passive` keeps it from lighting up
/// the screen, and a user who wants sound without banners can say so in Settings
/// — but it is a notification, and on a busy day there will be a stack of them.
///
/// ## What it deliberately does not carry
///
/// No callsign, no topic, no body. The panel is already on screen with the grid
/// and it says WHICH agent; a notification repeating that would be the same
/// information twice, in the channel that interrupts harder. This is one bit —
/// *something came back* — which is exactly what the ruling asked for and all a
/// Pavlovian cue can carry anyway.
@MainActor
enum ArrivalChime {

    /// Asked once, at LAUNCH.
    ///
    /// Onboarding was the first home for this and it was a dead end: the
    /// permission is deliberately non-blocking, so `allGranted` stays true, so
    /// the onboarding window never appears, so nothing ever asked. Measured — the
    /// chime shipped, arrivals fired for hours (`ambient: surfaced` ×4 in eight
    /// minutes) and not one notification was ever requested.
    ///
    /// Launch rather than first-arrival because a permission dialog that appears
    /// *because an agent finished* is precisely the interruption this feature
    /// exists to avoid. `requestAuthorization` is a no-op once decided, so
    /// calling it every launch costs nothing after the first.
    static func requestAuthorization() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.sound, .alert])
    }

    static var isAuthorized: Bool {
        get async {
            guard Bundle.main.bundleIdentifier != nil else { return false }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        }
    }

    /// One sound, now. Silent under Do Not Disturb because the system makes it so.
    static func play() {
        // A bundle id is required for UNUserNotificationCenter to exist at all;
        // the selftest and eval paths run the binary directly, and asking there
        // would trap rather than fail.
        guard Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        // Title only, and a plain one. `StateLegend` owns every user-facing noun
        // in the panel, and this is the one that leaves the panel.
        content.title = StateLegend.arrivalChimeTitle
        content.sound = .default
        // ACTIVE, and this is the whole feature working or not.
        //
        // It was `.passive` first, chosen to keep the notification off the
        // screen — and `.passive` is documented as adding the notification to
        // the list "without lighting up the screen OR PLAYING A SOUND". Five
        // chimes posted with no error and none of them made a noise, because a
        // silent sound is what was asked for. The one thing this feature exists
        // to do was disabled by the flag meant to make it polite.
        //
        // `.active` presents immediately and plays the sound. It also shows a
        // banner, which is the cost: the user can turn banners off in System
        // Settings and keep the sound, which is the right place for that choice
        // and not a preference this app should own.
        content.interruptionLevel = .active

        // ONE identifier, so each arrival replaces the last rather than
        // stacking. With ~20 sessions a fresh id per arrival builds a wall of
        // identical rows in Notification Center by the end of a day — the
        // notification-badge pattern this product is meant to be the opposite
        // of. Re-adding under the same id still alerts; it just does not pile up.
        let request = UNNotificationRequest(
            identifier: "tranquility-base.arrival", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            // Logged on success too. A feature whose correct behaviour is a
            // small noise has no visible failure mode — silence is both "it
            // worked and you were in Do Not Disturb" and "it has never once
            // run", and the log is the only thing that can tell them apart.
            Permissions.log(error.map { "chime: not delivered — \($0)" } ?? "chime: posted")
        }
    }
}
