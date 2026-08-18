import AppKit
import Foundation
import TranquilityCore
import UserNotifications

/// The four sounds the app makes.
///
/// ## History
///
/// This replaces `ArrivalChime`, which played one named system sound ("Tink") for
/// one event. The reasoning there was sound and is preserved below, because the
/// two constraints it identified still bind:
///
/// > It was `UNUserNotificationCenter` first, on the reasoning that the app cannot
/// > read Focus state — `~/Library/DoNotDisturb/DB/` is TCC-protected and there is
/// > no public API — so handing the system a request and letting IT apply Do Not
/// > Disturb was the only way to honour the ruling's condition without asking for
/// > Full Disk Access. It worked exactly as designed and the design was wrong.
/// > Every chime was delivered — 36 of them sitting in Notification Center — and
/// > not one made a noise, because the user is in Do Not Disturb essentially
/// > always. Honouring DND meant never chiming.
///
/// Ruled 11 Aug, and still in force: *"I'm always in Do Not Disturb and I don't
/// mind hearing a little chime occasionally."* So sound plays directly. No
/// notification, no permission, no Notification Center entry, nothing
/// accumulating.
///
/// ## Why bundled files rather than a system sound
///
/// `ArrivalChime` argued that "shipping an audio file to say one short thing is
/// weight for nothing," and for one cue that was right. Four cues need to read as
/// a FAMILY — same timbre, differing in note count and contour — and the system
/// set cannot do that: those sounds are unrelated to each other by construction.
///
/// The set was designed against measurement rather than taste. The short version:
///
///   - Differentiate by RHYTHM and NOTE COUNT, not melody. IEC 60601-1-8 encoded
///     medical-alarm identity in melody and fewer than 30% of trained subjects
///     could identify them at 100% accuracy after practice.
///   - Play once, never repeat, never require acknowledgement. Aviation defines a
///     warning as repeated and non-cancelable and a caution as one presentation;
///     that structure, not timbre, is what makes a sound read as an error.
///   - Sharpness is UPPER-PARTIAL energy, not pitch. A first attempt sat at a
///     2045 Hz spectral centroid against Funk's 732 and was rejected as "a little
///     ice pick on my brain."
///
/// The shipped voice is modelled on the ocarina Eric Aadahl used for Rocky's
/// everyday speech in *Project Hail Mary*, measured from a sample of the film:
/// D4 → G4, a perfect fourth, with partials taken from the film's calmest passage
/// (1.000 / 0.125 / 0.042 / 0.011). Chosen over thicker candidates on the
/// explicit ground that simple and euphonious wins for a sound heard a hundred
/// times a day; personality can be added later.
///
/// Full record and the generator:
/// ~/Documents/deep-research/2026-08-18-agent-earcon-design/
///
/// ## The one behaviour change worth knowing
///
/// `NSSound(named:)` on a SYSTEM sound plays at the volume the user chose for
/// alerts. A bundled file plays at app volume, so these are no longer under that
/// slider. Deliberate: the cues are mixed to peak −15 dBFS (−19 for `dispatched`)
/// so they sit under dialogue rather than competing with it, and an alert-volume
/// scaling would undo that mixing.
enum Earcons {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [EarconGate.Cue: NSSound] = [:]

    /// A cue that NOTIFIES. The gate is evaluated by the caller, on the main
    /// actor, where `recorder` and `coordinator.speech` are safe to read — rather
    /// than snapshotted into a background-readable cache, which would be one more
    /// piece of mutable state to go stale.
    @MainActor
    static func play(_ cue: EarconGate.Cue, gate: EarconGate) {
        if let why = gate.refusal(for: cue) {
            Permissions.log("earcon: dropped \(cue.rawValue) — \(why)")
            return
        }
        emit(cue)
    }

    /// A cue that ACKNOWLEDGES something the user just did, and is therefore
    /// UNGATED. `listening` is the only member of this class, for two reasons.
    ///
    /// First, the gate would veto it with its own trigger: the mic being open is
    /// what `listening` announces, so `userIsSpeaking` is true by construction at
    /// the moment it fires.
    ///
    /// Second, the failure modes are not symmetric. A notification that gets
    /// dropped costs a glance at the grid. "The mic is open, talk now" going
    /// missing costs a whole utterance spoken into nothing — it is the one cue
    /// whose absence the user cannot route around, because they are relying on it
    /// to know when to start. So it never asks permission.
    ///
    /// The agent-is-speaking case takes care of itself: opening the mic while the
    /// voice is playing is a deliberate gesture and that gesture STOPS the voice
    /// (see the ⌥-while-speaking handling in main.swift), so there is nothing to
    /// talk over by the time audio is flowing.
    ///
    /// Callable from any thread: this fires from the microphone's audio callback,
    /// which is not on the main queue and must never block.
    nonisolated static func acknowledge(_ cue: EarconGate.Cue) {
        DispatchQueue.main.async { emit(cue) }
    }

    @MainActor
    private static func emit(_ cue: EarconGate.Cue) {
        lock.lock()
        var sound = cache[cue]
        if sound == nil, let url = url(for: cue) {
            sound = NSSound(contentsOf: url, byReference: true)
            cache[cue] = sound
        }
        lock.unlock()

        guard let sound else {
            Permissions.log("earcon: no audio for \(cue.rawValue)")
            return
        }
        // Stopped first, or a second cue inside the first's decay is swallowed
        // rather than retriggered — which reads as the sound being unreliable
        // rather than as two events landing close together. Inherited from
        // ArrivalChime, where it was found the hard way.
        sound.stop()
        if !sound.play() {
            Permissions.log("earcon: \(cue.rawValue) play refused")
        }
    }

    /// File name on disk. `needsYou` is `needs-you.wav` because the generator
    /// writes kebab-case and the generator is the source of truth.
    private static func fileName(_ cue: EarconGate.Cue) -> String {
        cue == .needsYou ? "needs-you" : cue.rawValue
    }

    private static func url(for cue: EarconGate.Cue) -> URL? {
        let name = fileName(cue)
        if let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            return url
        }
        // Unbundled `swift run` has no Resources directory. Fall back to the repo
        // copy so the sounds work in development without a full bundle.sh.
        let repo = URL(fileURLWithPath: #filePath)          // .../Sources/TranquilityApp/Earcons.swift
            .deletingLastPathComponent()                    // .../Sources/TranquilityApp
            .deletingLastPathComponent()                    // .../Sources
            .deletingLastPathComponent()                    // repo root
            .appendingPathComponent("Resources/Sounds/\(name).wav")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    /// Sweep up after the notification era.
    ///
    /// The chime posted 36 notifications that were delivered, suppressed by Do Not
    /// Disturb, and left sitting in Notification Center — litter from a mechanism
    /// this app no longer uses. It clears its own, at launch, every launch: it
    /// posts none now, so the call is a no-op forever after the first one, and an
    /// app that leaves a pile of undismissable rows behind a deleted feature is
    /// not one anybody should trust with a login item.
    static func clearOldNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
