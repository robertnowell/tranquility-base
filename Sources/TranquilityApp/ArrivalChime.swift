import AppKit
import Foundation
import TranquilityCore
import UserNotifications

/// The sound an agent makes when it comes back.
///
/// Replaces the spoken callsign, ruled 10 Aug: "they give a little sound
/// indicator that something's come back. That's Pavlovian, and it tells you
/// there's something ready for you to work."
///
/// ## Why this is `NSSound` and not a notification
///
/// It was `UNUserNotificationCenter` first, on the reasoning that the app cannot
/// read Focus state — `~/Library/DoNotDisturb/DB/` is TCC-protected and there is
/// no public API — so handing the system a request and letting IT apply Do Not
/// Disturb was the only way to honour the ruling's condition without asking for
/// Full Disk Access.
///
/// It worked exactly as designed and the design was wrong. Every chime was
/// delivered — 36 of them sitting in Notification Center, authorisation granted,
/// sound enabled, banner style set — and not one made a noise, because the user
/// is in Do Not Disturb essentially always. Honouring DND meant never chiming.
///
/// Ruled 11 Aug, superseding the condition in the original ruling:
///
/// > "I'm always in Do Not Disturb and I don't mind hearing a little chime
/// > occasionally. For now, don't not announce on return just because they're in
/// > Do Not Disturb."
///
/// So the sound plays directly. No notification, no permission, no Notification
/// Center entry, nothing accumulating. The app already plays audio through this
/// path for every announcement it has ever spoken; a chime is not a different
/// kind of thing and does not need a different mechanism.
///
/// A settings toggle is the eventual home for "chime or not" — deliberately not
/// built, because a preference nobody has asked to change is a setting that
/// exists to be explained.
@MainActor
enum ArrivalChime {

    /// A named system alert rather than a bundled asset: already on every Mac,
    /// already at the volume the user chose for alerts, and shipping an audio
    /// file to say one short thing is weight for nothing.
    ///
    /// "Tink" on purpose — short, soft-edged, pitched to carry over a fan
    /// without being a bell. "Glass" and "Hero" announce themselves, "Basso"
    /// reads as an error, and "Submarine" is a second of decay for an event
    /// that is already over.
    static let soundName = "Tink"

    private static var sound: NSSound?

    /// Sweep up after the notification era.
    ///
    /// The chime posted 36 notifications that were delivered, suppressed by Do
    /// Not Disturb, and left sitting in Notification Center — litter from a
    /// mechanism this app no longer uses. It clears its own, at launch, every
    /// launch: it posts none now, so the call is a no-op forever after the first
    /// one, and an app that leaves a pile of undismissable rows behind a deleted
    /// feature is not one anybody should trust with a login item.
    static func clearOldNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// One sound, now. Plays under Do Not Disturb, deliberately.
    static func play() {
        if sound == nil { sound = NSSound(named: soundName) }
        guard let sound else {
            Permissions.log("chime: no system sound named \(soundName)")
            return
        }
        // Stopped first, or a second arrival inside the first's decay is
        // swallowed rather than retriggered — which reads as the chime being
        // unreliable rather than as two arrivals landing close together.
        sound.stop()
        Permissions.log(sound.play() ? "chime: played" : "chime: play refused")
    }
}
