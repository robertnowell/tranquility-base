import Foundation

/// The macOS identity envelope around one build of the same product.
///
/// Production and development intentionally compile the same target. These
/// values come from Info.plist so the difference stays in packaging rather
/// than growing compile-time branches through product behaviour.
public enum AppChannel: String, Sendable {
    case production
    case development
    case test
}

public enum AppIdentity {
    public static var channel: AppChannel {
        let raw = Bundle.main.object(forInfoDictionaryKey: "TBAppChannel") as? String
        return raw.flatMap(AppChannel.init(rawValue:)) ?? .production
    }

    public static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? "Tranquility Base"
    }

    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.robertnowell.voice-dispatch"
    }

    public static var updatesEnabled: Bool {
        // Old published bundles predate the key and must retain their updater.
        (Bundle.main.object(forInfoDictionaryKey: "TBUpdatesEnabled") as? Bool) ?? true
    }

    public static var databaseSchemaVersion: Int {
        (Bundle.main.object(forInfoDictionaryKey: "TBDatabaseSchemaVersion") as? Int) ?? 18
    }
}

/// Preferences that describe the product, not one code-signing identity.
///
/// `UserDefaults.standard` follows CFBundleIdentifier. Keeping product choices
/// there would make the two lanes silently disagree about the microphone,
/// voices, panel width, diagnostics, and key verdicts. Sparkle and TCC restart
/// bookkeeping deliberately stay in standard defaults; they belong to one
/// identity and must not leak into the other.
public enum ProductDefaults {
    public static let suiteName = "com.robertnowell.voice-dispatch.shared"

    public static var shared: UserDefaults {
        // `suiteName` is fixed and valid. The fallback makes command-line test
        // bundles usable even on a platform that declines named suites.
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    public static let migratedKeys: [String] = [
        "audioInputPreference",
        "systemVoiceIdentifier",
        "elevenLabsVoiceId",
        "panelCollapsed",
        "diagnostics.sendFailureReports",
        "keycheck.verdict.anthropic-api-key",
        "keycheck.verdict.elevenlabs-api-key",
        "keycheck.verdict.assemblyai-api-key",
        "keycheck.verdict.openai-api-key",
    ]

    /// Import the pre-split production preferences once, key by key.
    ///
    /// Development may be the first new build launched, so its `.standard`
    /// domain is empty. Reading the old production domain explicitly preserves
    /// the choices the installed app already owns. Never overwrite a shared
    /// value: after migration, it is the authority for both lanes.
    public static func migrateLegacyProductionValues() {
        guard let legacy = UserDefaults(suiteName: "com.robertnowell.voice-dispatch")
        else { return }
        migrate(keys: migratedKeys, from: legacy, to: shared)
    }

    /// Pure migration seam for the unit test; production uses the two named
    /// domains above. Existing shared choices always win.
    static func migrate(keys: [String], from source: UserDefaults, to destination: UserDefaults) {
        for key in keys where destination.object(forKey: key) == nil {
            guard let value = source.object(forKey: key) else { continue }
            destination.set(value, forKey: key)
        }
    }
}
