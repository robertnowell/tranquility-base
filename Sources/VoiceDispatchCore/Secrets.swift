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

    /// Read-through cache.
    ///
    /// Every keychain read is a potential authorisation prompt, and the app touches
    /// secrets on every summarize and every utterance. Uncached, that reads as macOS
    /// nagging endlessly even after "Always Allow" — the grant is fine, the call
    /// volume is the problem. One read per key per launch.
    private static let cache = SecretCache()

    private final class SecretCache: @unchecked Sendable {
        private var values: [Key: String?] = [:]
        private let lock = NSLock()

        /// Only successes are cached.
        ///
        /// Caching a failure made one bad read permanent: `values[key] = nil` stores
        /// `.some(nil)`, which the lookup treats as a hit, so the key stayed missing
        /// for the life of the process and the good voice never came back. A miss is
        /// cheap to retry — it is one small file read — and a wrong answer that
        /// never re-checks is expensive.
        func value(for key: Key, load: () -> String?) -> String? {
            lock.lock()
            if let cached = values[key], let hit = cached { lock.unlock(); return hit }
            lock.unlock()

            let loaded = load()
            guard let loaded else { return nil }
            lock.lock()
            values[key] = loaded
            lock.unlock()
            return loaded
        }

        func invalidate(_ key: Key) {
            lock.lock(); values[key] = nil; values.removeValue(forKey: key); lock.unlock()
        }
    }

    // MARK: - Storage
    //
    // A 0600 file rather than the login keychain, for one decisive reason: a keychain
    // ACL trusts the *application that created the item*, and this project has two
    // binaries — `vdctl` and the app — with different code-signing identifiers. To
    // macOS they are unrelated applications, so whichever one didn't write the secret
    // is prompted for the login password every time, and re-signing on each rebuild
    // invalidates any "Always Allow" you grant.
    //
    // The honest security accounting: this same directory already holds your recorded
    // voice and your session transcripts as ordinary 0600 files. Keychain-protecting
    // an API key while the recordings sit beside it in the clear is theatre, not
    // defence. One consistent protection boundary — user-only file permissions — is
    // both simpler and easier to reason about.

    public static var fileURL: URL {
        QueueStore.supportDirectory.appendingPathComponent("secrets.json")
    }

    private static func readFile() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func writeFile(_ values: [String: String]) throws {
        try? PrivateStorage.createDirectory(at: fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: fileURL, options: [.atomic, .completeFileProtection])
        // Belt and braces — .atomic can replace the file and reset the mode.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Reads the file and NOTHING else.
    ///
    /// An earlier version fell back to the keychain per key when the file lacked one.
    /// That looked like a harmless migration path and was actually the bug: any key
    /// not yet migrated still triggered a keychain prompt, so the app kept asking for
    /// the login password even after the file existed. Migration is now explicit and
    /// happens once, from `vdctl` — the binary that owns the keychain items — so the
    /// app has no keychain code path at all.
    public static func read(_ key: Key) -> String? {
        cache.value(for: key) { readFile()[key.rawValue].flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// Explicit, one-time move of every key out of the keychain into the file.
    /// Run from `vdctl`, which created the items and therefore already has access.
    @discardableResult
    public static func migrateFromKeychain() throws -> [Key] {
        var values = readFile()
        var moved: [Key] = []
        for key in Key.allCases where values[key.rawValue] == nil {
            if let existing = readUncached(key) {
                values[key.rawValue] = existing
                moved.append(key)
            }
        }
        if !moved.isEmpty { try writeFile(values) }
        moved.forEach { cache.invalidate($0) }
        return moved
    }

    private static func readUncached(_ key: Key) -> String? {
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

    /// Writes to the 0600 file. The value never passes through argv.
    public static func write(_ key: Key, value: String) throws {
        var values = readFile()
        values[key.rawValue] = value
        try writeFile(values)
        cache.invalidate(key)
    }

    /// Legacy keychain writer, kept only so existing items remain readable for the
    /// one-time migration in `read`.
    static func writeToKeychain(_ key: Key, value: String) throws {
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
        cache.invalidate(key)
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
