import Foundation
import Darwin

/// Nonsecret launch identities. Native credentials remain owned by the CLI.
public struct SavedAccount: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var configDirectory: String
    public var command: String
    public var directory: String?
    public var email: String?
    public var organization: String?
    public var backend: String { ClaudeCodeAdapter().id }
    public var root: URL { URL(fileURLWithPath: configDirectory, isDirectory: true).standardizedFileURL }
    public var registry: URL { root.appendingPathComponent("sessions") }
    public var projects: URL { root.appendingPathComponent("projects") }
    public var trustFile: URL { root.appendingPathComponent(".claude.json") }

    public init(id: String = UUID().uuidString.lowercased(), label: String,
                configDirectory: String, command: String = AgentDefaults.fallback,
                directory: String? = nil) {
        self.id = id; self.label = label
        self.configDirectory = (configDirectory as NSString).expandingTildeInPath
        self.command = command; self.directory = directory
    }

    /// Scope the environment inside the final shell, after shell startup.
    /// Authentication conflicts in settings are checked by the native status preflight.
    public func scopedCommand(_ command: String) -> String {
        let removed = Self.authenticationOverrides.map { "-u \($0)" }.joined(separator: " ")
        return "env \(removed) CLAUDE_CONFIG_DIR=\(SessionLauncher.shellQuoted(root.path)) \(command)"
    }

    public static let authenticationOverrides = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_PROFILE",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    ]
}

public enum AccountConfigurationError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let reason): return reason } }
}

/// Atomic, locked local registry; never contains access or refresh tokens.
public final class SavedAccountStore: @unchecked Sendable {
    public static let shared = SavedAccountStore(fileURL: QueueStore.supportDirectory.appendingPathComponent("saved-accounts.json"))
    private let lock = NSLock()
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func all() -> [SavedAccount] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }
    private func read() -> [SavedAccount] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decode(data)) ?? []
    }
    private static func decode(_ data: Data) throws -> [SavedAccount] {
        let values = try JSONDecoder().decode([SavedAccount].self, from: data)
        let roots = values.map { $0.root.resolvingSymlinksInPath().path }
        guard Set(values.map(\.id)).count == values.count, Set(roots).count == values.count,
              !roots.contains(defaultRoot.resolvingSymlinksInPath().path),
              values.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.configDirectory.hasPrefix("/") && !$0.label.isEmpty }) else {
            throw AccountConfigurationError.invalid("Saved account entries contain duplicate or invalid identities.")
        }
        return values
    }
    public func account(_ id: String) -> SavedAccount? { all().first { $0.id == id } }
    public func save(_ account: SavedAccount) throws {
        lock.lock(); defer { lock.unlock() }
        let descriptor = try Self.acquireWriteLock(fileURL)
        defer { Self.releaseWriteLock(descriptor) }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try Self.decode(Data(contentsOf: fileURL))
        }
        guard !account.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              account.configDirectory.hasPrefix("/"), UUID(uuidString: account.id) != nil,
              account.root.path != NSHomeDirectory(),
              !KnownHarnesses.all.contains(where: { $0.id == account.id }) else {
            throw AccountConfigurationError.invalid("Choose an account name and a separate profile folder.")
        }
        var values = read()
        if let existing = values.first(where: { $0.id == account.id }), existing.root != account.root {
            throw AccountConfigurationError.invalid("A saved account’s profile cannot be moved. Import it as a new entry.")
        }
        let canonical = account.root.resolvingSymlinksInPath()
        guard canonical != Self.defaultRoot.resolvingSymlinksInPath(),
              !values.contains(where: { $0.id != account.id && $0.root.resolvingSymlinksInPath() == canonical }) else {
            throw AccountConfigurationError.invalid("That profile already belongs to a saved account.")
        }
        values.removeAll { $0.id == account.id }; values.append(account)
        try Self.write(values, to: fileURL)
        ClaudeAgentsCLI.invalidate()
    }
    static func acquireWriteLock(_ url: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(url.path + ".lock", O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AccountConfigurationError.invalid("Could not open the account store lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw AccountConfigurationError.invalid("Another account update is in progress. Try again shortly.")
        }
        return descriptor
    }
    static func releaseWriteLock(_ descriptor: Int32) { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    public var isReadable: Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        return (try? Self.decode(Data(contentsOf: fileURL))) != nil
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    public var roots: [URL] { [Self.defaultRoot] + all().map(\.root) }
    public func targetID(root: URL) -> String? {
        let canonical = root.resolvingSymlinksInPath()
        if canonical == Self.defaultRoot.resolvingSymlinksInPath() { return ClaudeCodeAdapter().id }
        return all().first { $0.root.resolvingSymlinksInPath() == canonical }?.id
    }
    public func root(targetID: String) -> URL? {
        targetID == ClaudeCodeAdapter().id ? Self.defaultRoot : account(targetID)?.root
    }
    public func backend(_ selection: String) -> String { account(selection)?.backend ?? selection }
}

/// Durable provenance survives process exit and a change to the default account.
public struct SessionAccountBinding: Codable, Equatable, Sendable {
    public var targetID: String
    public var configDirectory: String
}

public final class SessionAccountStore: @unchecked Sendable {
    public static let shared = SessionAccountStore(fileURL: QueueStore.supportDirectory.appendingPathComponent("session-accounts.json"))
    private let lock = NSLock()
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    private func read() -> [String: SessionAccountBinding] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: SessionAccountBinding].self, from: data)) ?? [:]
    }
    public var isReadable: Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        return (try? JSONDecoder().decode([String: SessionAccountBinding].self, from: Data(contentsOf: fileURL))) != nil
    }
    public func binding(_ sessionID: String) -> SessionAccountBinding? {
        lock.lock(); defer { lock.unlock() }; return read()[sessionID]
    }
    public func bind(_ sessionID: String, targetID: String, root: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let descriptor = try SavedAccountStore.acquireWriteLock(fileURL)
        defer { SavedAccountStore.releaseWriteLock(descriptor) }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try JSONDecoder().decode([String: SessionAccountBinding].self, from: Data(contentsOf: fileURL))
        }
        var values = read()
        let binding = SessionAccountBinding(targetID: targetID, configDirectory: root.standardizedFileURL.path)
        if let old = values[sessionID] {
            guard old == binding else { throw AccountConfigurationError.invalid("This conversation has conflicting saved-account origins.") }
            return
        }
        values[sessionID] = binding
        try SavedAccountStore.write(values, to: fileURL)
    }
}

public struct SavedAccountIdentity: Sendable, Equatable {
    public var email: String
    public var organization: String?
    public static func decode(_ data: Data, account: SavedAccount) throws -> SavedAccountIdentity {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["loggedIn"] as? Bool == true,
              value["authMethod"] as? String == "claude.ai",
              let email = value["email"] as? String, !email.isEmpty,
              let directory = value["configDirectory"] as? String,
              URL(fileURLWithPath: directory).standardizedFileURL == account.root else {
            throw AccountConfigurationError.invalid("This profile needs a subscription sign-in, or another authentication route overrides it.")
        }
        let identity = SavedAccountIdentity(email: email, organization: value["orgId"] as? String)
        if let expected = account.email, expected != identity.email {
            throw AccountConfigurationError.invalid("This profile is signed into a different account. Reconnect the saved entry before launching.")
        }
        if let expected = account.organization, expected != identity.organization {
            throw AccountConfigurationError.invalid("This profile’s organization changed. Reconnect the saved entry before launching.")
        }
        return identity
    }
    public static func read(account: SavedAccount, directory: URL? = nil) throws -> SavedAccountIdentity {
        guard let binary = ClaudeAgentsCLI.resolveBinary() else {
            throw AccountConfigurationError.invalid("The agent executable is not installed.")
        }
        var environment = ProcessInfo.processInfo.environment
        for key in SavedAccount.authenticationOverrides { environment.removeValue(forKey: key) }
        environment["CLAUDE_CONFIG_DIR"] = account.root.path
        environment["PATH"] = ClaudeCodeAdapter().pathCandidates.joined(separator: ":")
        switch Subprocess.run(binary, ["auth", "status"], environment: environment, directory: directory, stdin: Data(), timeout: 10) {
        case .failure: throw AccountConfigurationError.invalid("Could not verify the saved login. Reconnect this account before launching.")
        case .success(let output): return try decode(Data(output.utf8), account: account)
        }
    }
}

extension SavedAccount {
    /// Repair only this account, retaining the shared TB event/KB destinations.
    public func installIntegration() throws {
        let desired = RulesStore.desired()
        ClaudeConfigRepair.repairStaleWriteRules(settingsURL: root.appendingPathComponent("settings.json"))
        if case .unavailable(let reason) = HookManifest.repair(settings: root.appendingPathComponent("settings.json"), desired: desired?.hooks) {
            throw AccountConfigurationError.invalid("Account saved; hook setup needs attention: " + reason)
        }
        if let source = desired?.skills, let target = SkillManifest.targets.first(where: { $0.id == id }),
           case .unavailable(let reason) = SkillManifest.repair(target: target, source: source) {
            throw AccountConfigurationError.invalid("Account saved; skill setup needs attention: " + reason)
        }
    }
}
