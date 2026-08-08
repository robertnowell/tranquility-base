import Foundation

/// The ordered cast of session voices, user-editable and persisted.
///
/// Was a hardcoded array in Coordinator ("the cast of a radio drama does not
/// change because the agency signed someone new") — re-ruled 05 Aug: the
/// settings pane manages the cast, so it lives in a file the pane can write.
/// Order still matters: assignment is round-robin in roster order. Existing
/// assignments are stored per session (`session_voice`), so editing the
/// roster never reshuffles a voice anyone has already heard.
public enum VoiceRoster {
    /// The original hardcoded cast (Robert's 05 Aug audition, plus Amelia —
    /// the configured narrator he asked to keep in rotation) — the seed for
    /// installs that have never saved a roster, so nothing changes on upgrade.
    public static let seed = [
        "CwhRBWXzGAHq8TQ4Fs17",  // Roger — laid-back, resonant
        "EXAVITQu4vr4xnSDxMaL",  // Sarah — mature, reassuring
        "IKne3meq5aSn9XLyUdCD",  // Charlie — deep, energetic
        "JBFqnCBsd6RMkjVDRZzb",  // George — warm storyteller
        "N2lVS1w4EtoT3dr4eOWO",  // Callum — husky trickster
        "SOYHLrjzK2X1ezoPC6cr",  // Harry — fierce warrior
        "XrExE9yKIg1WjnnlVkGX",  // Matilda — knowledgeable, professional
        "hpp4J3VqNfWAUOO0d1Us",  // Bella — professional, bright
        "nPczCjzI2devNBz1zQrb",  // Brian — deep, comforting
        "onwK4e9ZLuTAKqWW03F9",  // Daniel — steady broadcaster
        "pqHfZKP75CvOlQylNhV4",  // Bill — wise, balanced
        "mZ8K1MPRiT5wDQaasg3i",  // Alexander Kensington — studio quality
        "NFG5qt843uXKj4pFvR7C",  // Adam Stone — smooth, deep
        "ZF6FPAbjXT4488VcRRnw",  // Amelia — the narrator, by request
        "EGxJIQ5TF187oclOp8aT",  // Kay — cloned, added by request
    ]

    /// Overridable for tests; the app always uses the support directory.
    nonisolated(unsafe) public static var fileURL: URL =
        QueueStore.supportDirectory.appendingPathComponent("roster.json")

    /// The ordered roster. A MISSING (or unreadable) file seeds the original
    /// cast; a file that says `[]` means the user emptied the roster on
    /// purpose, and that emptiness is honored — callers fall back to the
    /// default narrator voice, never to a resurrected cast.
    public static func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL) else { return seed }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? seed
    }

    public static func save(_ ids: [String]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: fileURL)
    }
}
