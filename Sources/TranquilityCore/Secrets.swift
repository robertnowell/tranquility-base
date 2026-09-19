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
    /// Local credential changes notify the one managed session, without carrying
    /// credentials in notification payloads. Other-process changes are caught
    /// by the uncached Hub-token read before every managed operation.
    public static let hubIdentityDidChange = Notification.Name("TranquilityHubIdentityDidChange")
    /// The Keychain service name, deliberately NOT renamed with the product.
    ///
    /// This string is the lookup key for every stored credential. Changing it does
    /// not migrate anything — it orphans the existing items and silently reads back
    /// nil, which surfaces as "the model provider is down" rather than "your key
    /// moved". Any rename must ship with a read-old-write-new migration, so until
    /// that exists the 2026 product rename (Voice Dispatch → Tranquility Base)
    /// stops at the door.
    public static let service = "voice-dispatch"

    public enum Key: String, Sendable, CaseIterable {
        case anthropicAPIKey = "anthropic-api-key"
        case elevenLabsAPIKey = "elevenlabs-api-key"
        case assemblyAIAPIKey = "assemblyai-api-key"
        case openAIAPIKey = "openai-api-key"
        /// The hub's device token: this Mac's credential for the mirror,
        /// minted by the hub when the Mac was connected. Not a key a person
        /// pastes, so no console URL.
        case hubToken = "hub-token"
        /// This Mac's proof-of-possession key. For an enclave key this is the
        /// enclave's own wrapped blob, which is useless on any other machine;
        /// for the software fallback it is a real private key. Never leaves
        /// this file, and never travels anywhere: only signatures do.
        case deviceKey = "device-key"
        /// crobot, through Jarvis. Minted in Jarvis under user settings, API
        /// Keys tab, with NO permissions: crobot only calls `/api/auth/me`
        /// with it and that route enforces no scope. Jarvis refuses an empty
        /// scope list, so tick one harmless box and choose specific
        /// organizations, never all, and never a `coframe-integration:*`
        /// scope. It does not expire and is revocable from the same screen.
        case crobotAPIKey = "crobot-api-key"
        /// Local OpenCode's server password, when its server has one. Genuinely
        /// optional: a server started without `--password` accepts
        /// unauthenticated requests from localhost, so the absence of this is a
        /// configuration, not a fault.
        case openCodePassword = "opencode-password"

        /// The provider's name, as a person would say it.
        public var provider: String {
            switch self {
            case .anthropicAPIKey: return "Anthropic"
            case .elevenLabsAPIKey: return "ElevenLabs"
            case .assemblyAIAPIKey: return "AssemblyAI"
            case .openAIAPIKey: return "OpenAI"
            case .hubToken: return "Tranquility Knowledge Base"
            case .deviceKey: return "This Mac's key"
            case .crobotAPIKey: return "crobot"
            case .openCodePassword: return "OpenCode"
            }
        }

        /// What breaks without it, never what it is.
        public var purpose: String {
            switch self {
            case .anthropicAPIKey: return "spoken summaries, about $0.001 each"
            case .elevenLabsAPIKey: return "the voice; without it, the system one"
            case .assemblyAIAPIKey: return "the live transcript while you speak"
            case .openAIAPIKey: return "Whisper, the durable transcript when streaming fails"
            case .hubToken: return "the mirror: every page and turn, in the hub"
            case .deviceKey: return "proves this Mac is this Mac, for anything that spends"
            case .crobotAPIKey: return "your crobot agents, as rows you can answer"
            case .openCodePassword: return "a local OpenCode server that asks for one"
            }
        }

        /// Whether a person ever types this in.
        ///
        /// Most of these are pasted from somebody's console, and every one of
        /// those needs a checklist row to paste it into: a credential the app
        /// can store but offers nowhere to enter is a dead end, which is what
        /// `testEveryPastableCredentialHasARowToTypeItIn` exists to prevent.
        ///
        /// Two are not pasted. The hub mints its token during the connect
        /// flow, and this Mac makes its own device key. Neither has a row
        /// because neither has anything for a person to do, and stating that
        /// here rather than as an exception in the test means the next key
        /// added has to answer the question rather than inherit an omission.
        public var isPasted: Bool {
            switch self {
            case .hubToken, .deviceKey: return false
            default: return true
            }
        }

        /// Where the key actually comes from.
        ///
        /// A prompt that asks for a key without saying where to get one has
        /// handed the user a search. Lives on the key rather than on the
        /// checklist row so the menu editor and the first-run row cannot drift
        /// apart. All four verified to resolve, 26 Aug.
        public var consoleURL: URL? {
            switch self {
            case .anthropicAPIKey: return URL(string: "https://console.anthropic.com/settings/keys")
            case .elevenLabsAPIKey: return URL(string: "https://elevenlabs.io/app/settings/api-keys")
            case .assemblyAIAPIKey: return URL(string: "https://www.assemblyai.com/dashboard/api-keys")
            case .openAIAPIKey: return URL(string: "https://platform.openai.com/api-keys")
            case .hubToken: return nil
            // Made on this machine, by this machine. There is nowhere to go
            // and get one, which is the property that makes it worth having.
            case .deviceKey: return nil
            // Jarvis mints it, under user settings. No stable deep link to that
            // tab exists, so the console root is the honest answer rather than
            // a guessed fragment that 404s.
            case .crobotAPIKey: return URL(string: "https://jarvis.coframe.com/settings")
            // Nothing to sign up for: it is whatever password the user passed
            // to their own `opencode serve`. A console URL here would point at
            // a product page and teach them nothing.
            case .openCodePassword: return nil
            }
        }
    }

    /// The credential a cloud agent provider authenticates with, or nil for a
    /// provider that needs none.
    ///
    /// The one place the mapping lives, so a checklist row, a key check and a
    /// provider adapter cannot disagree about which secret a provider uses.
    /// Keyed by `AgentProvider.id`, deliberately NOT by a string built from
    /// the raw value: "crobot" and "crobot-api-key" are two vocabularies and
    /// deriving one from the other is how they drift.
    /// NOT named `provider`: `Key` already has an instance property by that
    /// name (the provider's name, as a person would say it), and a static
    /// function sharing it reads as the same concept from the wrong side.
    public static func credential(forProvider id: String) -> Key? {
        switch id {
        case "crobot": return .crobotAPIKey
        case "opencode": return .openCodePassword
        default: return nil
        }
    }

    /// Read-through cache.
    ///
    /// Every keychain read is a potential authorisation prompt, and the app touches
    /// secrets on every summarize and every utterance. Uncached, that reads as macOS
    /// nagging endlessly even after "Always Allow" — the grant is fine, the call
    /// volume is the problem. One read per key per launch.
    static let cache = SecretCache()

    /// Internal rather than private so its behaviour can be tested without
    /// writing to the real secrets file.
    public final class SecretCache: @unchecked Sendable {
        public init() {}
        private var values: [Key: String?] = [:]
        private let lock = NSLock()

        /// Only successes are cached.
        ///
        /// Caching a failure made one bad read permanent: `values[key] = nil` stores
        /// `.some(nil)`, which the lookup treats as a hit, so the key stayed missing
        /// for the life of the process and the good voice never came back. A miss is
        /// cheap to retry — it is one small file read — and a wrong answer that
        /// never re-checks is expensive.
        public func value(for key: Key, load: () -> String?) -> String? {
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
    // binaries — `tbase` and the app — with different code-signing identifiers. To
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

    /// Set by the app so a failed read explains itself instead of silently
    /// degrading the voice.
    public nonisolated(unsafe) static var trace: (@Sendable (String) -> Void)?

    private static func readFile() -> [String: String] {
        do {
            let data = try Data(contentsOf: fileURL)
            let dict = try JSONDecoder().decode([String: String].self, from: data)
            Secrets.trace?("read \(fileURL.path) -> keys \(dict.keys.sorted())")
            return dict
        } catch {
            Secrets.trace?("read failed at \(fileURL.path): \(error)")
            return [:]
        }
    }

    private static func writeFile(_ values: [String: String]) throws {
        try? PrivateStorage.createDirectory(at: fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // No .completeFileProtection: it is a data-protection class designed for iOS
        // device lock, and on macOS it can make the file unreadable depending on
        // lock state. The protection here is the 0600 mode and the 0700 directory,
        // which do not depend on anything being unlocked.
        try encoder.encode(values).write(to: fileURL, options: [.atomic])
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
    /// happens once, from `tbase` — the binary that owns the keychain items — so the
    /// app has no keychain code path at all.
    public static func read(_ key: Key) -> String? {
        if key == .hubToken { return readFile()[key.rawValue].flatMap { $0.isEmpty ? nil : $0 } }
        return cache.value(for: key) { readFile()[key.rawValue].flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// Explicit, one-time move of every key out of the keychain into the file.
    /// Run from `tbase`, which created the items and therefore already has access.
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
        if key == .hubToken { NotificationCenter.default.post(name: hubIdentityDidChange, object: nil) }
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
