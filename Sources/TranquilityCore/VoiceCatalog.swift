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
        get { UserDefaults.standard.string(forKey: defaultsKey) ?? fallbackVoiceId }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Cached on disk so the menu is populated instantly at launch and a network
    /// blip never empties the picker.
    public static var cacheURL: URL {
        QueueStore.supportDirectory.appendingPathComponent("voices.json")
    }

    public static func cached() -> [Voice] {
        guard let data = try? Data(contentsOf: cacheURL),
              let voices = try? JSONDecoder().decode([Voice].self, from: data)
        else { return [] }
        return voices
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
        return voices
    }
}
