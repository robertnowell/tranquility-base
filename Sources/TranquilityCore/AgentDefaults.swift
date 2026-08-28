import Foundation

/// How this machine starts an agent, in one place: the command and the
/// directory — one pair per harness, plus which harness is the default.
///
/// Ruled 12 Aug, after the revival feature shipped a second launch path and the
/// two disagreed: a session started from the panel ran unattended, and the same
/// session REVIVED from the panel stopped at every tool call, because only the
/// first carried `--dangerously-skip-permissions`. Robert: "any new or revived
/// session gets launched under the same parameters."
///
/// So the command is a setting rather than a constant, and both paths read it.
/// The shape follows Vibe Kanban's, which solves the same problem: the user
/// configures how their agent is launched — `claude`, `codex`, with or without
/// the flag that lets it work without asking — and everything that starts an
/// agent obeys it.
///
/// Resume is not a second setting. `--resume <id>` is appended to whatever this
/// says, so a session brought back is the same kind of agent as a session
/// started, by construction rather than by two constants agreeing.
///
/// Went per-harness 25 Aug (App-lane, default launcher): until then this was
/// one global command and one global directory, no concept of which harness
/// they belonged to — fine while only Claude Code could be launched fresh, not
/// once Codex could too (see `LaunchGreeting.awaitCodexRegistration`, its
/// sibling change). Harness ids are `HarnessAdapter.id` ("claude-code",
/// "codex") — the one seam this codebase already has for harness identity,
/// not a third hardcoded string pair alongside `ClaudeCodeAdapter`/
/// `CodexAdapter`'s own.
public enum AgentDefaults {

    /// What this machine used before the setting existed, and still Claude
    /// Code's default: the away channel is the product, and an agent that
    /// stops to ask is an agent you have to go back to the terminal for.
    public static let fallback = "claude --dangerously-skip-permissions"

    /// Codex's equivalent. `--dangerously-bypass-approvals-and-sandbox` is
    /// the real flag (`codex --help`), not a guess; "YOLO" in conversation,
    /// the same shape as Claude's own skip-permissions default.
    ///
    /// `--dangerously-bypass-hook-trust` rides with it, and is the price of
    /// the needs-you signal on this harness. Codex will not run a hook whose
    /// config it has not had reviewed, and it does not complain when it
    /// declines: measured 28 Aug against codex-cli 0.150.1, an untrusted
    /// `hooks.json` produces no hook, no warning and no log line, which is
    /// exactly the silent-death failure `HookManifest` exists to catch on the
    /// Claude Code side. Trust is granted by a "Hooks need review" menu in the
    /// TUI, persisted to `~/.codex/config.toml` as
    /// `[hooks.state."<path>:<event>:<group>:<index>"] trusted_hash`, and
    /// invalidated whenever the hooks file changes, so every `install-hooks`
    /// would put that menu in front of every pane's next launch. TB's own
    /// launcher refuses to auto-accept it (`neverAutoAcceptNeedles`), and
    /// rightly: pressing a security prompt on the user's behalf is not a thing
    /// a launcher should learn to do.
    ///
    /// So the flag, whose own help text names this exact situation: "Intended
    /// only for automation that already vets hook sources." TB wrote the hooks
    /// file itself, from `HookManifest`, which is as vetted as a hook source
    /// gets here.
    ///
    /// It stays a plain part of the COMMAND STRING rather than a separate
    /// setting, because the command is already a per-harness field the user
    /// edits (Settings, and `agent-command.json` on disk). Anyone who wants
    /// the review gate back deletes eleven words and approves the menu once by
    /// hand; nothing in the app needs a second switch to express that.
    public static let codexFallback =
        "codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"

    /// What `codexFallback` was before hooks needed trusting. A machine that
    /// stored this verbatim never CHOSE it, it just inherited the old default,
    /// so `normalized()` upgrades it in place. Anything else the user typed is
    /// left exactly as typed.
    static let codexFallbackBeforeHookTrust = "codex --dangerously-bypass-approvals-and-sandbox"

    /// The fallback for a given harness, falling back itself to Claude
    /// Code's for any id this hasn't heard of — better than crashing on a
    /// harness added after this file last knew about one.
    public static func fallback(for harness: String) -> String {
        harness == CodexAdapter().id ? codexFallback : fallback
    }

    /// Where a new agent starts when you have not said otherwise, for a given
    /// harness. The home directory, as it always was — ruled 15 Aug that this
    /// becomes a setting alongside the command, global for now: "we could
    /// just make that a global setting for now and see if we need more
    /// granular later." (Per-harness as of 25 Aug is exactly the "more
    /// granular later.")
    ///
    /// A REVIVED agent ignores this entirely and uses the directory its own
    /// transcript records, because resuming a conversation somewhere it never
    /// ran is not the same session in any sense that matters.
    public static var fallbackDirectory: String { NSHomeDirectory() }

    /// Overridable for tests; the app always uses the support directory. The
    /// filename is the old one so a machine that has already set a command
    /// keeps it across this change.
    nonisolated(unsafe) public static var fileURL: URL =
        QueueStore.supportDirectory.appendingPathComponent("agent-command.json")

    private struct HarnessEntry: Codable {
        var command: String
        var directory: String?
    }

    private struct Stored: Codable {
        var byHarness: [String: HarnessEntry]?
        var defaultHarness: String?

        // The pre-25-Aug shape: one global command/directory, no harness
        // concept. Decoded only so `normalized()` can migrate it; never
        // written again once this file is re-saved under the new shape.
        var command: String?
        var directory: String?
    }

    private static func stored() -> Stored? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func write(byHarness: [String: HarnessEntry], defaultHarness: String) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(
            Stored(byHarness: byHarness, defaultHarness: defaultHarness))
        else { return }
        try? data.write(to: fileURL)
    }

    /// What's actually on disk, migrated to the current shape if it predates
    /// it. The old shape's single command/directory becomes Claude Code's
    /// entry — its fallback command was already Claude-shaped — and
    /// `defaultHarness` migrates to Claude Code too, so nobody's upgrade
    /// silently changes what a bare `New Agent` press launches.
    private static func normalized() -> (byHarness: [String: HarnessEntry], defaultHarness: String) {
        let claude = ClaudeCodeAdapter().id
        guard let raw = stored() else { return ([:], claude) }
        if let byHarness = raw.byHarness {
            return (upgradedCodexHookTrust(byHarness), raw.defaultHarness ?? claude)
        }
        var map: [String: HarnessEntry] = [:]
        if raw.command != nil || raw.directory != nil {
            map[claude] = HarnessEntry(command: raw.command ?? fallback, directory: raw.directory)
        }
        return (map, claude)
    }

    /// A stored Codex command that is VERBATIM the old default gains
    /// `--dangerously-bypass-hook-trust`; anything else is untouched.
    ///
    /// Read-time and value-scoped on purpose. Changing a default does nothing
    /// for the machines already carrying the old one, and this app's own
    /// setting file is exactly such a machine: `agent-command.json` has held
    /// `codex --dangerously-bypass-approvals-and-sandbox` since 25 Aug, so
    /// shipping the new fallback alone would have left every existing install
    /// with hooks that silently never fire. That is the whole bug class this
    /// guards.
    ///
    /// Equality against the OLD default, not a substring check or an append,
    /// is what keeps this from overwriting a decision. A user who deleted the
    /// flag on purpose, pinned a path, or added flags of their own typed
    /// something that is not this string, and gets to keep it. The upgrade is
    /// therefore idempotent and applies at most once per machine, since the
    /// result no longer equals the old default.
    ///
    /// It does not WRITE. Rewriting the file from a read path would mean a
    /// launch mutating settings behind the user's back, and `save` already
    /// persists the upgraded value the next time anything sets a command.
    private static func upgradedCodexHookTrust(
        _ byHarness: [String: HarnessEntry]
    ) -> [String: HarnessEntry] {
        let codex = CodexAdapter().id
        guard var entry = byHarness[codex],
              entry.command.trimmingCharacters(in: .whitespaces)
                  == codexFallbackBeforeHookTrust
        else { return byHarness }
        entry.command = codexFallback
        var upgraded = byHarness
        upgraded[codex] = entry
        return upgraded
    }

    /// The configured command for a harness, or its fallback when nothing
    /// has been set.
    ///
    /// A stored EMPTY string is treated as unset rather than honored — unlike
    /// the voice roster, where emptying it is a meaningful choice. There is no
    /// useful meaning for "launch agents with no command", and a blank field
    /// saved by accident would otherwise break every launch on the machine.
    public static func load(for harness: String) -> String {
        guard let entry = normalized().byHarness[harness],
              !entry.command.trimmingCharacters(in: .whitespaces).isEmpty
        else { return fallback(for: harness) }
        return entry.command
    }

    /// The current default harness's command — every pre-25-Aug call site
    /// reads this, and keeps working unchanged against "whatever's default."
    public static func load() -> String { load(for: normalized().defaultHarness) }

    public static func save(_ command: String, for harness: String) {
        var (map, defaultHarness) = normalized()
        var entry = map[harness] ?? HarnessEntry(command: fallback(for: harness), directory: nil)
        entry.command = command
        map[harness] = entry
        write(byHarness: map, defaultHarness: defaultHarness)
    }

    public static func save(_ command: String) { save(command, for: normalized().defaultHarness) }

    /// The configured start directory for a harness, or home when nothing is
    /// set.
    ///
    /// A path that does not EXIST falls back rather than being honoured: the
    /// setting is typed by hand, a typo is one keystroke away, and a launch
    /// into a directory that is not there fails inside a detached tmux pane
    /// the panel cannot see into any more easily than a Terminal window it
    /// once failed in. Home always exists.
    public static func directory(for harness: String) -> String {
        guard let path = normalized().byHarness[harness]?.directory?
            .trimmingCharacters(in: .whitespaces), !path.isEmpty
        else { return fallbackDirectory }
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else { return fallbackDirectory }
        return expanded
    }

    public static func directory() -> String { directory(for: normalized().defaultHarness) }

    /// What the settings pane shows for a harness: what was typed, not what
    /// it resolved to, so a path that has gone missing is visible as itself
    /// rather than silently replaced by home in the field the user is
    /// editing.
    public static func directoryAsTyped(for harness: String) -> String {
        normalized().byHarness[harness]?.directory ?? ""
    }

    public static func directoryAsTyped() -> String { directoryAsTyped(for: normalized().defaultHarness) }

    public static func save(directory: String, for harness: String) {
        var (map, defaultHarness) = normalized()
        var entry = map[harness] ?? HarnessEntry(command: fallback(for: harness), directory: nil)
        entry.directory = directory
        map[harness] = entry
        write(byHarness: map, defaultHarness: defaultHarness)
    }

    public static func save(directory: String) { save(directory: directory, for: normalized().defaultHarness) }

    /// Which harness a bare `New Agent` press launches. Settings only ever
    /// changes this through an explicit action — viewing or editing a
    /// harness's own command/directory must never silently make it the
    /// default.
    public static var defaultHarness: String {
        get { normalized().defaultHarness }
        set {
            let (map, _) = normalized()
            write(byHarness: map, defaultHarness: newValue)
        }
    }
}
