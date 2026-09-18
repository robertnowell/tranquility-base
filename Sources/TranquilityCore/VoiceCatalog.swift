import Foundation

/// The voices on the account, so the picker offers what you actually have rather
/// than a hardcoded list that drifts the moment you add one.
public struct Voice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let category: String

    public init(id: String, name: String, category: String) {
        self.id = id
        self.name = name
        self.category = category
    }
}

public enum VoiceCatalog {
    /// Where the chosen voice lives. A single string in the app's own preferences:
    /// it is a preference, not state to reconcile, and nothing else depends on it.
    private static let defaultsKey = "elevenLabsVoiceId"

    /// Sarah, the previous hardcoded default, so an install that has never chosen
    /// keeps the voice it already had.
    public static let fallbackVoiceId = "EXAVITQu4vr4xnSDxMaL"

    public static var selectedVoiceId: String {
        get { ProductDefaults.shared.string(forKey: defaultsKey) ?? fallbackVoiceId }
        set { ProductDefaults.shared.set(newValue, forKey: defaultsKey) }
    }

    /// Cached on disk so the menu is populated instantly at launch and a network
    /// blip never empties the picker.
    /// Overridable for tests; the app always uses the support directory. Same
    /// seam and same reason as `VoiceRoster.fileURL` — once the roster filters
    /// itself against this cache, a test that did not own the file would be
    /// asserting against whichever voices this particular machine's account
    /// happens to hold today.
    nonisolated(unsafe) public static var cacheURL: URL =
        QueueStore.supportDirectory.appendingPathComponent("voices.json")

    public static func cached() -> [Voice] {
        guard let data = try? Data(contentsOf: cacheURL),
              let voices = try? JSONDecoder().decode([Voice].self, from: data)
        else { return [] }
        return voices
    }

    /// Every voice id this install has EVER seen, with the name it had.
    ///
    /// `voices.json` is the account, so a voice deleted there vanishes from it —
    /// and with it the only thing that could turn an id back into a word. That
    /// is how "a voice with voice_id 'EGxJIQ5TF187oclOp8aT' was not found"
    /// reached the hint line: at the moment the app most needed to say WHICH
    /// voice had gone, the id was all it had left.
    ///
    /// Append-only and never pruned, because its whole purpose is to outlive a
    /// deletion. It is a few dozen short strings; there is nothing to reclaim.
    nonisolated(unsafe) public static var namesURL: URL =
        QueueStore.supportDirectory.appendingPathComponent("voice-names.json")

    /// The last name known for an id — the live catalogue first, then the
    /// ledger. `nil` when this install has genuinely never seen the voice.
    public static func lastKnownName(for id: String) -> String? {
        if let live = cached().first(where: { $0.id == id }) { return live.name }
        guard let data = try? Data(contentsOf: namesURL),
              let ledger = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return ledger[id]
    }

    /// How to SAY a voice id in one clause, for a line a human reads.
    ///
    /// The catalogue's names carry a sales tail — "Sarah - Mature, Reassuring,
    /// Confident" — which is right in a picker row and wrong mid-sentence, so
    /// only the part before the dash survives. An id nobody can name degrades to
    /// its first eight characters rather than to nothing: unlovely, but it is
    /// what the settings pane and the log both show, so it can still be matched
    /// up with something.
    public static func spokenName(for id: String?) -> String {
        guard let id, !id.isEmpty else { return "that agent's voice" }
        guard let name = lastKnownName(for: id) else { return "voice \(id.prefix(8))" }
        let head = name.split(separator: "-", maxSplits: 1)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? name
        return "\u{201C}\(head.isEmpty ? name : head)\u{201D}"
    }

    /// Fold a fetched catalogue into the ledger. Merge, never replace: the
    /// entries worth keeping are exactly the ones the fetch no longer returns.
    static func rememberNames(_ voices: [Voice]) {
        guard !voices.isEmpty else { return }
        var ledger: [String: String] = [:]
        if let data = try? Data(contentsOf: namesURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            ledger = stored
        }
        for voice in voices { ledger[voice.id] = voice.name }
        guard let encoded = try? JSONEncoder().encode(ledger) else { return }
        try? PrivateStorage.createDirectory(at: namesURL.deletingLastPathComponent())
        try? encoded.write(to: namesURL, options: .atomic)
        PrivateStorage.protect(namesURL)
    }

    @discardableResult
    public static func refresh() async -> [Voice] {
        guard let key = Secrets.read(.elevenLabsAPIKey) else { return cached() }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v2/voices?page_size=100")!)
        request.timeoutInterval = 10
        request.setValue(key, forHTTPHeaderField: "xi-api-key")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["voices"] as? [[String: Any]]
        else { return cached() }

        let voices: [Voice] = raw.compactMap {
            guard let id = $0["voice_id"] as? String, let name = $0["name"] as? String
            else { return nil }
            return Voice(id: id, name: name, category: ($0["category"] as? String) ?? "other")
        }
        guard !voices.isEmpty else { return cached() }

        if let encoded = try? JSONEncoder().encode(voices) {
            try? PrivateStorage.createDirectory(at: cacheURL.deletingLastPathComponent())
            try? encoded.write(to: cacheURL, options: .atomic)
            PrivateStorage.protect(cacheURL)
        }
        // Before the account's answer becomes the only record of it.
        rememberNames(voices)
        return voices
    }
}
