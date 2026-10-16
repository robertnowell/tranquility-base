import Foundation

/// The voice is off: announcements and pulls arrive as text only.
///
/// Ruled 16 Oct 2026: "a lot of times I just don't want to talk." Muted is a
/// SILENT VERSION, not a quiet one. Nothing is synthesized and nothing is
/// played, so no ElevenLabs round trip sits between the press and the card
/// and no characters are bought; playing silence would have kept both costs
/// and saved neither. With no audio there is nothing for the highlight to
/// follow, so the card lands fully lit.
///
/// A product preference, so it lives in `ProductDefaults.shared` and both
/// lanes agree. Read per utterance by `SpeechChain`, so unmuting takes effect
/// on the next thing you hear, with no restart.
public enum VoiceMute {
    static let key = "voiceMuted"

    /// Injectable so a test never touches the machine's own defaults.
    public nonisolated(unsafe) static var defaults: UserDefaults = ProductDefaults.shared

    /// Absent means off: the voice is the product, and silence is a choice.
    public static var isOn: Bool {
        get { defaults.bool(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }
}
