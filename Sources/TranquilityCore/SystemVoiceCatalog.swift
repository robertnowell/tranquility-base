import AVFoundation
import Foundation

/// Which macOS voice the fallback should use.
///
/// `SystemSpeechProvider` has always accepted a `voiceIdentifier` and nothing ever
/// passed one, so every announcement got `AVSpeechSynthesizer`'s locale default —
/// compact Samantha, the lowest-quality voice macOS ships. Meanwhile this machine
/// already had `Ava (Premium)` installed, plus enhanced Alex, Allison, Ava, Evan and
/// the Siri voice Nicky. The good voices were present and unreachable.
///
/// Worth recording how that stayed hidden: `say -v '?'` lists only the legacy
/// SpeechSynthesis voices, so it reported "Samantha and 40 novelty voices" and made
/// the machine look bare. `AVSpeechSynthesisVoice.speechVoices()` — what the app
/// actually speaks through — reports the premium and enhanced ones. Probing with the
/// wrong API produced a confident wrong answer about the hardware.
public enum SystemVoiceCatalog {

    /// UserDefaults key for an explicit choice. Absent means "pick the best".
    static let preferenceKey = "systemVoiceIdentifier"

    /// Quality first, because that is the whole point; then a stable name order so
    /// the choice does not wander between launches for no reason.
    ///
    /// `AVSpeechSynthesisVoiceQuality` is not `Comparable`, so the rank is explicit
    /// rather than inferred from the raw value — the enum's numbering is Apple's to
    /// change and this ordering is a decision of ours.
    public static func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    /// Every installed voice for a language, best first.
    public static func voices(matching language: String = "en-US") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .sorted {
                let (a, b) = (rank($0.quality), rank($1.quality))
                return a == b ? $0.name < $1.name : a > b
            }
    }

    /// The identifier the fallback provider should speak with, or nil to leave
    /// `AVSpeechSynthesizer` to its own default.
    ///
    /// Nil is a real answer, not a failure: a machine with only compact voices has
    /// nothing better to offer, and passing the compact identifier explicitly would
    /// be the same voice with more ceremony.
    public static func preferredIdentifier(language: String = "en-US") -> String? {
        if let chosen = UserDefaults.standard.string(forKey: preferenceKey) {
            // Honour an explicit choice only while it is still installed — a voice can
            // be removed in Settings, and a stale identifier makes AVSpeechSynthesizer
            // fall back silently, which would look like this fix had regressed.
            if AVSpeechSynthesisVoice.speechVoices().contains(where: { $0.identifier == chosen }) {
                return chosen
            }
        }
        guard let best = voices(matching: language).first,
              rank(best.quality) > 1
        else { return nil }
        return best.identifier
    }

    /// Set or clear the explicit choice. Clearing returns to "best installed".
    public static func choose(_ identifier: String?) {
        if let identifier {
            UserDefaults.standard.set(identifier, forKey: preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
    }

    /// Whether the machine has anything better than the compact default, so the app
    /// can say "there are better voices available in Settings" rather than leaving a
    /// user to conclude this is how it sounds.
    public static func hasBetterVoiceAvailable(language: String = "en-US") -> Bool {
        voices(matching: language).contains { rank($0.quality) > 1 }
    }

    // MARK: - Recommendations, for a machine that has none of them

    /// The free voices worth having, named as Settings names them.
    ///
    /// A stock Mac has NONE of these: it ships compact Samantha plus forty novelty
    /// voices, and the route to better ones is five surfaces deep — Accessibility →
    /// Read & Speak → System voice → Voice → the download cloud. Nobody finds that by
    /// accident, so an app whose entire product is a voice has to name them out loud.
    ///
    /// Curated, not exhaustive, because size is part of the advice: Ava (Enhanced) is
    /// 264MB and Alex is 912MB, so "download them all" is not a recommendation.
    public static let recommended: [(name: String, note: String)] = [
        ("Ava (Premium)",      "the best free voice on macOS"),
        ("Allison (Enhanced)", "warm — 43MB, the cheapest real upgrade"),
        ("Evan (Enhanced)",    "male, natural"),
        ("Ava (Enhanced)",     "264MB, only if Premium is unavailable"),
    ]

    /// Which recommended voices are here, and which are one download away.
    ///
    /// Matched on NAME rather than identifier, because the identifier is the unstable
    /// half: premium voices moved from `com.apple.ttsbundle.*` to
    /// `com.apple.voice.premium.*`, so an identifier allowlist would report every
    /// voice as missing after an OS upgrade and send users to re-download what they
    /// already had.
    public static func recommendationStatus(language: String = "en-US")
        -> (installed: [String], missing: [(name: String, note: String)]) {
        let present = Set(voices(matching: language).map(\.name))
        var installed: [String] = []
        var missing: [(name: String, note: String)] = []
        for entry in recommended {
            if present.contains(entry.name) { installed.append(entry.name) }
            else { missing.append(entry) }
        }
        return (installed, missing)
    }

    /// Where to send the user.
    ///
    /// Deliberately the plain pane. Deeper anchors (`?Spoken_Content`, `?Speech`,
    /// `?ReadAndSpeak`) could not be verified from here — confirming where Settings
    /// lands needs assistive access the shell does not have — and an anchor that does
    /// NOT resolve opens Settings wherever it was last left, which reads as a broken
    /// button. A pane that always lands somewhere real beats a guess that sometimes
    /// lands nowhere.
    public static let settingsURL =
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"

    /// The clicks the deep link cannot skip, so the app can spell them out rather than
    /// implying the button finishes the job.
    public static let remainingSteps = "Read & Speak → System voice → Voice → ↓"

    /// The free voices as catalogue entries, so the picker can list them beside the
    /// paid ones instead of showing an empty pane.
    ///
    /// Without this the Voices face read "15 of 0 on roster" on a machine with no
    /// ElevenLabs key: `VoiceCatalog.cached()` is ElevenLabs-only and returns nothing,
    /// while a stale roster of 15 ids survived from a previous session. Zero available
    /// voices was never true — the machine had forty-odd installed and the app could
    /// not see any of them.
    ///
    /// Category carries quality, because "free" alone does not tell you that Ava
    /// (Premium) and compact Samantha are not the same offer.
    public static func asCatalogueVoices(language: String = "en-US") -> [Voice] {
        voices(matching: language).map { v in
            let tier: String
            switch rank(v.quality) {
            case 3: tier = "Free · Premium"
            case 2: tier = "Free · Enhanced"
            default: tier = "Free · Compact"
            }
            return Voice(id: v.identifier, name: v.name, category: tier)
        }
    }
}
