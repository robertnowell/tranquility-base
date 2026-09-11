import Foundation

/// Config problems TB fixes for the user without asking, because the fix is
/// deterministic and safe. The user is non-technical (ruled 10 Sep), so they
/// are never shown the problem or a command; the app repairs it and logs what
/// it changed so we can tell for sure.
///
/// Today it fixes one thing: permission rules written as `Write(path)`, which
/// claude 2.1 ignores with a warning on every launch, rewritten to `Edit(path)`,
/// which it honors. That is the exact rule a deep-research install left in
/// Kristen's settings, printed twice on her screen. Rewriting it is safe
/// (`Edit` is the documented replacement and covers all file-editing tools)
/// and idempotent (a second run finds nothing to do).
public enum ClaudeConfigRepair {

    /// Pure: rewrite an allow-list, `Write(...)` to `Edit(...)`, de-duplicated,
    /// order preserved. Returns the new list and how many entries changed.
    /// Testable with no filesystem.
    public static func rewriteAllow(_ rules: [String]) -> (rules: [String], changed: Int) {
        var seen = Set<String>()
        var out: [String] = []
        var changed = 0
        for rule in rules {
            var fixed = rule
            if rule.hasPrefix("Write(") {
                fixed = "Edit(" + rule.dropFirst("Write(".count)
                changed += 1
            }
            if seen.insert(fixed).inserted { out.append(fixed) }
        }
        return (out, changed)
    }

    /// Read a settings.json, rewrite its `permissions.allow` in place, write it
    /// back atomically with a backup. Returns the number of rules changed, and
    /// 0 (touching nothing) when there is nothing to do or the file cannot be
    /// read or parsed, so a malformed file is never made worse.
    @discardableResult
    public static func repairStaleWriteRules(
        settingsURL: URL,
        trace: (@Sendable (String) -> Void)? = nil
    ) -> Int {
        guard let data = try? Data(contentsOf: settingsURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var perms = root["permissions"] as? [String: Any],
              let allow = perms["allow"] as? [String]
        else { return 0 }

        let (rewritten, changed) = rewriteAllow(allow)
        guard changed > 0 else { return 0 }

        perms["allow"] = rewritten
        root["permissions"] = perms
        guard let outData = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return 0 }

        // A backup first, same discipline HookManifest uses when it rewrites
        // this same file.
        try? data.write(to: settingsURL.appendingPathExtension("tb-backup"))
        do {
            try outData.write(to: settingsURL, options: .atomic)
            trace?("claude-health: rewrote \(changed) stale Write() rule"
                + "\(changed == 1 ? "" : "s") to Edit() in \(settingsURL.lastPathComponent)")
            return changed
        } catch {
            trace?("claude-health: could not write \(settingsURL.lastPathComponent): \(error)")
            return 0
        }
    }

    /// The user's own settings file, the one claude reads and the one the
    /// warning names.
    public static var userSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }
}
