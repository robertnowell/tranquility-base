import Foundation

/// Every agent that speaks ACP, as a table.
///
/// **This is the deliverable.** Measured in Paseo's own commits on 13 Sep 2026,
/// adding a vendor that speaks ACP cost 6 files and 15 lines, while a vendor
/// that spoke no shared protocol cost 72 files and 12,984 — roughly 900 to 1
/// for what their changelog calls the same event. No amount of abstraction
/// quality closes that gap; only speaking the protocol does.
///
/// So an entry carries a NAME and a COMMAND and nothing else. It deliberately
/// does NOT carry capabilities: the agent declares those in the handshake
/// (`ACPWire.Initialized.capabilities`), so a table written today cannot go
/// stale when a vendor ships a release tomorrow. A capability column would be
/// four copies of somebody else's fact, each with its own chance to be wrong,
/// which is the failure this codebase has already recorded twice.
public struct ACPCatalog: Sendable {

    public struct Entry: Sendable, Equatable, Identifiable {
        /// Stable, lowercase, and used as the `AgentProvider.id`, so a row's
        /// harness column says which agent it came from.
        public let id: String
        /// What a person calls it.
        public let name: String
        /// argv. The first element is resolved against PATH by `resolve`,
        /// because a catalog must not hard-code where somebody installed
        /// something.
        public let command: [String]

        public init(id: String, name: String, command: [String]) {
            self.id = id
            self.name = name
            self.command = command
        }
    }

    /// The published catalog.
    ///
    /// Sourced from Paseo's built-in catalog and Vibe Kanban's routing table,
    /// both surveyed 13 Sep 2026. Entries are listed whether or not this
    /// machine has them: `installed()` answers that, and a table that hid what
    /// it did not find would make "which agents could I use" unanswerable.
    public static let published: [Entry] = [
        Entry(id: "opencode",     name: "OpenCode",      command: ["opencode", "acp"]),
        Entry(id: "cursor",       name: "Cursor",        command: ["cursor-agent", "acp"]),
        Entry(id: "devin",        name: "Devin",         command: ["devin", "acp"]),
        Entry(id: "gemini",       name: "Gemini CLI",    command: ["gemini", "--experimental-acp"]),
        Entry(id: "amp",          name: "Amp",           command: ["amp", "acp"]),
        Entry(id: "auggie",       name: "Auggie",        command: ["auggie", "acp"]),
        Entry(id: "cline",        name: "Cline",         command: ["cline", "acp"]),
        Entry(id: "droid",        name: "Factory Droid", command: ["droid", "acp"]),
        Entry(id: "trae",         name: "TRAE",          command: ["trae", "acp"]),
        Entry(id: "kiro",         name: "Kiro",          command: ["kiro", "acp"]),
        Entry(id: "qwen",         name: "Qwen Code",     command: ["qwen", "--experimental-acp"]),
    ]

    /// Where to look, in order. Mirrors `HarnessAdapter.pathCandidates`, which
    /// exists for the same reason: a GUI app inherits launchd's PATH and not
    /// the user's shell, so every one of these would be "not installed" if we
    /// trusted `PATH` alone. That defect has already been recorded once for
    /// Codex.
    public static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.bun/bin",
        NSHomeDirectory() + "/.opencode/bin",
    ]

    /// The entry's command with its executable resolved to a full path, or nil
    /// when this machine does not have it.
    public static func resolve(_ entry: Entry,
                               paths: [String] = searchPaths,
                               exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> [String]? {
        // An absolute path in the table is taken as given, which is what makes
        // a test and a hand-configured agent possible without a second code
        // path.
        if entry.command[0].hasPrefix("/") {
            return exists(entry.command[0]) ? entry.command : nil
        }
        for directory in paths {
            let candidate = directory + "/" + entry.command[0]
            if exists(candidate) { return [candidate] + entry.command.dropFirst() }
        }
        return nil
    }

    /// Which published agents this machine actually has.
    public static func installed(
        _ entries: [Entry] = published,
        paths: [String] = searchPaths,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [(entry: Entry, command: [String])] {
        entries.compactMap { entry in
            resolve(entry, paths: paths, exists: exists).map { (entry, $0) }
        }
    }
}
