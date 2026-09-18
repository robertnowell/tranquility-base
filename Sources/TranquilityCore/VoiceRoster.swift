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
        // Kay (EGxJIQ5TF187oclOp8aT) was here — a CLONED voice, added by
        // request 05 Aug and deleted from the ElevenLabs account some time
        // before 11 Sep. A cloned id is the one kind that can disappear from
        // under a hardcoded list, and this one did: the seed kept minting it to
        // new sessions, every announcement took an HTTP 404 for it, and the
        // roster pane could not show the row to uncheck (see `rebuildVoiceRows`
        // — a roster id the catalogue does not list has no row). Removed from
        // the seed rather than only from the file, or a fresh install would
        // resurrect it. `load()` now filters the class, so a voice deleted
        // AFTER this ships needs no second edit here.
    ]

    /// How many system voices the roster seeds with.
    ///
    /// Enough to rotate — the whole point is that two sessions falling back do
    /// not become the same person — and few enough that the seed is the good
    /// ones rather than the whole catalogue. `voices(matching:)` is sorted by
    /// quality descending, so this takes the top of that ranking.
    static let systemSeedCount = 8

    /// The system roster's seed: the best installed English voices, in quality
    /// order. Machine-dependent by construction, unlike the ElevenLabs seed —
    /// there is no fixed list to hardcode, because what is installed differs per
    /// machine and per macOS version.
    public static var systemSeed: [String] {
        SystemVoiceCatalog.voices(matching: "en")
            .prefix(systemSeedCount).map(\.identifier)
    }

    /// Overridable for tests; the app always uses the support directory.
    nonisolated(unsafe) public static var fileURL: URL =
        QueueStore.supportDirectory.appendingPathComponent("roster.json")

    /// The system roster's own file. A SECOND file rather than a flag on the
    /// rows, because the two rosters are edited independently and a single file
    /// is exactly what went wrong: the settings pane lists both families and its
    /// toggle appended any checked id to the one roster, so checking a system
    /// voice put an Apple identifier into the cloud rotation. Two files make
    /// that unrepresentable rather than merely discouraged.
    nonisolated(unsafe) public static var systemFileURL: URL =
        QueueStore.supportDirectory.appendingPathComponent("roster-system.json")

    /// The ordered roster. A MISSING (or unreadable) file seeds the original
    /// cast; a file that says `[]` means the user emptied the roster on
    /// purpose, and that emptiness is honored — callers fall back to the
    /// default narrator voice, never to a resurrected cast.
    public static func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL) else { return seed }
        let stored = (try? JSONDecoder().decode([String].self, from: data)) ?? seed
        // Filtered on the way OUT, not merely on the way in. Whatever is on disk
        // — a file written by an older build, or hand-edited — a system
        // identifier is not a cloud voice, and returning one here is what sent
        // `com.apple.ttsbundle.siri_Nicky_en-US_premium` to ElevenLabs as a
        // voice id and took an HTTP 400 for it every five seconds.
        return onAccount(stored.filter { !SystemVoiceCatalog.isSystemVoice($0) })
    }

    /// Drop ids the ElevenLabs account no longer carries.
    ///
    /// Same shape and same reason as the system-identifier filter above, one
    /// class along: that one caught an id that could never have worked, this one
    /// catches an id that USED to. A cloned voice deleted on the account stays in
    /// the roster forever otherwise — it is minted to new sessions in round-robin
    /// order, 404s on every single announcement, and cannot be unchecked in the
    /// roster pane because a voice the catalogue does not list has no row there.
    /// Measured 11 Sep: one such id, 76 failed renders in seven minutes, and a
    /// raw 404 body on the hint line where a sentence belonged.
    ///
    /// The catalogue is EVIDENCE, not authority — it is a cache of the last
    /// successful fetch, so it is empty before the first one and stale after a
    /// network blip. Filtering on an empty or unfetched catalogue would silence
    /// every agent at once, which is far worse than the fault being fixed. So
    /// the filter only applies when the catalogue actually says something, and
    /// never returns nothing: if every roster id is unknown the catalogue is
    /// what is wrong, not the roster.
    static func onAccount(_ ids: [String]) -> [String] {
        let known = Set(VoiceCatalog.cached().map(\.id))
        guard !known.isEmpty else { return ids }
        let kept = ids.filter { known.contains($0) }
        return kept.isEmpty ? ids : kept
    }

    public static func save(_ ids: [String]) {
        write(ids.filter { !SystemVoiceCatalog.isSystemVoice($0) }, to: fileURL)
    }

    /// The system roster, seeded from what is actually installed.
    ///
    /// Same contract as `load()`: a missing file seeds, an explicitly empty file
    /// is honoured — callers fall back to the provider's own default voice,
    /// never to a resurrected cast.
    public static func loadSystem() -> [String] {
        guard let data = try? Data(contentsOf: systemFileURL) else { return systemSeed }
        let stored = (try? JSONDecoder().decode([String].self, from: data)) ?? systemSeed
        return stored.filter(SystemVoiceCatalog.isSystemVoice)
    }

    public static func saveSystem(_ ids: [String]) {
        write(ids.filter(SystemVoiceCatalog.isSystemVoice), to: systemFileURL)
    }

    private static func write(_ ids: [String], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: url)
    }

    /// Split a roster that predates there being two of them.
    ///
    /// This machine's file held 26 entries on 20 Aug — the 15 seeded ElevenLabs
    /// ids plus 11 Apple ones added through the settings pane on 13 Aug. The
    /// Apple entries were CHECKED ON PURPOSE, so they are moved rather than
    /// discarded: the user asked for those voices, just not for them to be
    /// dialled up as cloud ids.
    ///
    /// Runs once and is a no-op afterwards, keyed on the system file not
    /// existing yet. Idempotent by that test rather than by a stored flag,
    /// because the file IS the flag.
    @discardableResult
    public static func splitMixedRoster() -> (cloud: Int, system: Int)? {
        guard !FileManager.default.fileExists(atPath: systemFileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        let system = stored.filter(SystemVoiceCatalog.isSystemVoice)
        guard !system.isEmpty else { return nil }
        let cloud = stored.filter { !SystemVoiceCatalog.isSystemVoice($0) }
        write(cloud, to: fileURL)
        write(system, to: systemFileURL)
        return (cloud.count, system.count)
    }
}
