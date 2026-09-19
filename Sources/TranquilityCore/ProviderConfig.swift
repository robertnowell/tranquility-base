import Foundation

/// Where a cloud agent provider lives, read from the machine's own config.
///
/// The same shape as `HubApp.baseURL`, and deliberately the same file:
/// `~/.claude/hq.json` is already where this Mac records the addresses of
/// things it talks to, and a second config file would be a second place to
/// look when a provider is silent.
///
///     { "providers": { "crobot":   { "base_url": "https://..." },
///                      "opencode": { "base_url": "http://127.0.0.1:4096" } } }
///
/// **Absent means "not connected", never an error.** That is the whole
/// configuration surface and it is the rule `HubApp` already holds: a machine
/// that has never been told about a provider is not a machine in a broken
/// state, and returning nil rather than throwing is what lets the setup
/// checklist render a quiet row instead of a red one.
///
/// A provider is keyed by `AgentProvider.id`, so this never becomes a second
/// vocabulary for the same thing (the rule `Prerequisites.Item.hooks` already
/// follows with `HarnessAdapter.id`).
public enum ProviderConfig {

    /// The base URL configured for `provider`, or nil while it has none.
    public static func baseURL(_ provider: String,
                               config: URL = HubApp.configPath) -> URL? {
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = obj["providers"] as? [String: Any],
              let entry = providers[provider] as? [String: Any],
              let raw = entry["base_url"] as? String
        else { return nil }
        return normalize(raw)
    }

    /// Every provider this machine has an address for, whether or not it also
    /// has a credential. The setup checklist asks the two questions
    /// separately, because a URL with no key and a key with no URL fail
    /// differently and a row that averages them helps nobody.
    public static func configured(config: URL = HubApp.configPath) -> [String] {
        guard let data = try? Data(contentsOf: config),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = obj["providers"] as? [String: Any]
        else { return [] }
        return providers.keys.filter { baseURL($0, config: config) != nil }.sorted()
    }

    /// Write one provider's address, and leave everything else exactly as it
    /// was.
    ///
    /// `hq.json` is not this app's file. The page-writing skills read it, the
    /// indexer reads it, `HubApp` writes one key in it, and all of them put
    /// their own keys there. So this is a read, a merge and an atomic replace,
    /// exactly like `HubApp.setBaseURL`: every top-level key survives, and so
    /// does every provider other than the one being set. Clobbering a config
    /// file somebody else owns is the kind of thing discovered weeks later, by
    /// a tool that stopped finding its own setting.
    public static func setBaseURL(_ url: URL, for provider: String,
                                  config: URL = HubApp.configPath) throws {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: config),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        var providers = (obj["providers"] as? [String: Any]) ?? [:]
        var entry = (providers[provider] as? [String: Any]) ?? [:]
        var address = url.absoluteString
        while address.hasSuffix("/") { address.removeLast() }
        entry["base_url"] = address
        providers[provider] = entry
        obj["providers"] = providers
        let data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: a half-written hq.json is a machine that has lost its hub
        // address AND every provider it knew about.
        try data.write(to: config, options: .atomic)
    }

    /// Trimmed, and http or https only.
    ///
    /// The scheme check is not ceremony. A base URL is pasted, and a paste
    /// that arrives as `file:` or with no scheme at all would otherwise build
    /// a request that fails somewhere far from here, reported as the provider
    /// being down. Local OpenCode is genuinely `http://127.0.0.1`, so http
    /// cannot be refused.
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              url.scheme == "https" || url.scheme == "http", url.host != nil
        else { return nil }
        return url
    }
}
