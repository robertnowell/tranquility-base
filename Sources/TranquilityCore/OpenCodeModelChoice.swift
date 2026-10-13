import Foundation

/// **Which model a session this app creates on `opencode serve` runs on.**
///
/// Measured 12 Oct 2026, 6:12 PM: New Agent → OpenCode, one message, and the
/// row went red with "opencode reported a session error". The server's log
/// had the cause: a session created with no model runs on the server's
/// DEFAULT, and 2.0.23's default with no `model` configured is the newest
/// model in the catalog — `google/gemini-nano-banana-2.1` that evening, an
/// image model with a 65k window that refused the first turn; `meta/muse-
/// wonder` an hour later, age-gated. Meanwhile the TUI, in the same database,
/// ran `anthropic/claude-fable-5.1` because it remembers what the user last
/// picked. The app's sessions should run what the user runs.
///
/// Two sources, in the order OpenCode's own TUI consults them: the `model`
/// field of the global config (`~/.config/opencode/opencode.json(c)`, as
/// `provider/model`), then the TUI's own memory of the last pick
/// (`~/.local/state/opencode/model.json`, `recent[0]`, with its variant).
/// Nothing configured anywhere means nil, and the server's default stands,
/// which is exactly what happened before and is at least the server's choice
/// to make.
public struct OpenCodeModelChoice: Equatable, Sendable {
    public let providerID: String
    public let modelID: String
    public let variant: String?

    public init(providerID: String, modelID: String, variant: String? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.variant = variant
    }

    /// The `Model.Ref` body `POST /api/session` takes.
    public var ref: [String: String] {
        var ref = ["providerID": providerID, "id": modelID]
        if let variant { ref["variant"] = variant }
        return ref
    }

    public static func preferred(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> OpenCodeModelChoice? {
        let config = home.appendingPathComponent(".config/opencode")
        for name in ["opencode.json", "opencode.jsonc"] {
            if let data = try? Data(contentsOf: config.appendingPathComponent(name)),
               let chosen = fromConfig(data) {
                return chosen
            }
        }
        let state = home.appendingPathComponent(".local/state/opencode/model.json")
        if let data = try? Data(contentsOf: state) { return fromState(data) }
        return nil
    }

    /// `"model": "openrouter/anthropic/claude-fable-5.1"`: the first segment
    /// is the provider, the rest is the model id (which may itself contain
    /// slashes, as OpenRouter's do). JSONC comments are stripped first,
    /// crudely but enough for a key read.
    static func fromConfig(_ data: Data) -> OpenCodeModelChoice? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let stripped = text.replacingOccurrences(of: #"(?m)^\s*//.*$"#, with: "", options: .regularExpression)
        guard let object = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any],
              let model = object["model"] as? String else { return nil }
        return parse(model)
    }

    /// `{"recent":[{"providerID","modelID"}],"variant":{"provider/model":"medium"}}`.
    static func fromState(_ data: Data) -> OpenCodeModelChoice? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recent = (object["recent"] as? [[String: Any]])?.first,
              let providerID = recent["providerID"] as? String,
              let modelID = recent["modelID"] as? String else { return nil }
        let variant = (object["variant"] as? [String: String])?["\(providerID)/\(modelID)"]
        return OpenCodeModelChoice(providerID: providerID, modelID: modelID, variant: variant)
    }

    static func parse(_ model: String) -> OpenCodeModelChoice? {
        let parts = model.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return OpenCodeModelChoice(providerID: parts[0], modelID: parts[1])
    }
}
