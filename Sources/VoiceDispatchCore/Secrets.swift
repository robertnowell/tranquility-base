import Foundation
import Security

/// Keychain-backed credential storage.
///
/// Deliberately does NOT fall back to the ambient `ANTHROPIC_API_KEY` environment
/// variable. A stale key in a shell profile silently 401s every call, and because
/// the failure looks like a service outage rather than a config problem it is
/// genuinely hard to diagnose — it cost an hour during development. Anything that
/// shells out (the `claude -p` fallback provider) must likewise scrub it.
public enum Secrets {
    public static let service = "voice-dispatch"

    public enum Key: String, Sendable, CaseIterable {
        case anthropicAPIKey = "anthropic-api-key"
        case elevenLabsAPIKey = "elevenlabs-api-key"
        case assemblyAIAPIKey = "assemblyai-api-key"
        case openAIAPIKey = "openai-api-key"
    }

    public static func read(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Store via the Security framework rather than shelling out to `security`,
    /// so the value never appears in any process's argv.
    public static func write(_ key: Key, value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(base as CFDictionary)

        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ScriptError(message: "keychain write failed (OSStatus \(status))")
        }
    }

    public static func has(_ key: Key) -> Bool { read(key) != nil }

    /// Environment for any subprocess we spawn: the ambient Anthropic key is removed
    /// so a stale value in the user's shell cannot poison it.
    public static func scrubbedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        return env
    }
}
