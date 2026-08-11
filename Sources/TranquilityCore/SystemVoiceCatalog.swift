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
    static func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
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
}
