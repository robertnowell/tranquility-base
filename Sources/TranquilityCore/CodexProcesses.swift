import Foundation

/// Finds live, interactive Codex CLI processes on the machine — the
/// primitive `claude agents --json` gives Claude Code for free and Codex
/// has no equivalent for (`HarnessCapabilities.registersWithLiveness ==
/// false`). There is no Codex daemon or registry to ask "what's running and
/// under what session id" the way Claude Code's own CLI answers that
/// question; the process table and `lsof` are the only ground truth that
/// exists, so this reads them directly.
///
/// Measured live, 22 Aug, against real codex-cli 0.149.0 in an isolated
/// tmux socket: a fresh interactive launch's argv is exactly `["codex"]`;
/// resuming a specific thread (`codex resume <id>`, `CodexAdapter.
/// resumeArguments`) makes it `["codex", "resume", "<id>"]`. The rollout
/// file itself confirmed the thread id in argv matches the id Codex's own
/// `session_meta` record carries.
///
/// The reason this needs its own allowlist rather than a name match alone:
/// the desktop ChatGPT/Codex.app runs its own bundled `codex` binary for
/// its internal use — same executable name, an entirely different process
/// (`/Applications/Codex.app/Contents/Resources/codex -c
/// features.code_mode_host=true app-server --analytics-default-enabled`,
/// observed live on this machine, unrelated to any CLI session TB could
/// dispatch to). A broad `pkill -f codex` during this session's own Codex
/// measurement work came within one command of hitting it — confirmed
/// afterward, by process uptime, that it didn't. Filtering on the exact
/// interactive shape rather than excluding known-bad ones matches
/// `SessionDiscovery.isHeadless`'s own doctrine turned the other way:
/// positive evidence of an ordinary CLI session, not a blocklist of
/// everything else Codex might ever be running as.
public enum CodexProcesses {

    /// One process on the table whose argv matched the interactive
    /// allowlist below.
    public struct Candidate: Sendable, Equatable {
        public var pid: Int
        public var argv: [String]

        public init(pid: Int, argv: [String]) {
            self.pid = pid
            self.argv = argv
        }

        /// The session id this process is resuming, read straight off argv
        /// — `nil` for a fresh launch nobody has resumed yet. Whoever
        /// started the resume (TB, or the user typing it by hand) is
        /// unambiguous once this is non-nil: Codex writes the id into its
        /// own command line, so there is nothing left to infer.
        public var resumingSessionId: String? {
            guard argv.count == 3, argv[1] == "resume" else { return nil }
            return argv[2]
        }
    }

    /// Parses `ps -eo pid=,command=` output into interactive Codex
    /// candidates only. Pure — testable against captured `ps` text without
    /// a real process table, the same division `TmuxOwnership.match` and
    /// `ClaudeAgentsCLI.decodeSessions` already keep.
    ///
    /// The allowlist is exactly the two shapes measured live above: `codex`
    /// alone, or `codex resume <id>`. Anything else — `app-server`, any
    /// other flag or subcommand this repo has not measured — is excluded,
    /// on purpose. A naive space-split on the full command line cannot
    /// distinguish an argv element containing a space from two elements
    /// (`ps` gives no field boundary once flattened to text), but the
    /// failure direction is safe either way: a path or argument that
    /// happens to contain a space makes the candidate fail this allowlist
    /// and simply disappear, the same "fails closed" shape typing already
    /// follows everywhere else in this repo, never a wrong match.
    static func parse(_ psOutput: String) -> [Candidate] {
        var out: [Candidate] = []
        for line in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(of: " "),
                  let pid = Int(trimmed[trimmed.startIndex..<spaceIdx])
            else { continue }
            let commandLine = trimmed[trimmed.index(after: spaceIdx)...]
                .trimmingCharacters(in: .whitespaces)
            let argv = commandLine.split(separator: " ").map(String.init)
            guard let first = argv.first,
                  (first as NSString).lastPathComponent == "codex"
            else { continue }
            guard argv.count == 1 || (argv.count == 3 && argv[1] == "resume") else { continue }
            out.append(Candidate(pid: pid, argv: argv))
        }
        return out
    }

    /// Every interactive Codex process on the machine right now.
    public static func running() -> [Candidate] {
        guard case .success(let raw) = Subprocess.run(
            "/bin/ps", ["-eo", "pid=,command="], timeout: 3)
        else { return [] }
        return parse(raw)
    }

    /// Attribute one session id to a liveness verdict, three-way, matching
    /// `SessionDiscovery.Liveness` exactly for the reason that type's own
    /// doc comment gives: `unknown` is the state that matters, not a
    /// compromise between the other two.
    ///
    /// - A candidate whose argv names this id directly (`resume <id>`,
    ///   whoever typed it) is unambiguous: `.live`, with its real pid.
    /// - Otherwise, cwd is the only signal left, and it is evidence of
    ///   "something Codex is running in this directory", never evidence of
    ///   IDENTITY — a bare, unresumed `codex` launch in the same directory
    ///   as this session's own cwd could be this exact session (started
    ///   fresh and never yet resumed) or an unrelated one. Reads `.unknown`
    ///   rather than guessing either way, matching "typing fails CLOSED"
    ///   (never assume a target is safe) while stopping short of
    ///   `SessionDiscovery`'s own "positive evidence" wrong direction (this is
    ///   not proof of absence either, so it must not read as `.gone`).
    /// - No candidate at all in the target directory is positive evidence
    ///   of absence: `.gone`.
    public static func liveness(
        forSessionId id: String,
        cwd: String?,
        among candidates: [Candidate],
        cwdOf: (Int) -> String? = ProcessProbe.cwd(of:)
    ) -> (liveness: SessionDiscovery.Liveness, pid: Int?) {
        if let matched = candidates.first(where: { $0.resumingSessionId == id }) {
            return (.live, matched.pid)
        }
        let unresumedInSameDirectory = cwd.map { dir in
            candidates.contains { $0.resumingSessionId == nil && cwdOf($0.pid) == dir }
        } ?? false
        return unresumedInSameDirectory ? (.unknown, nil) : (.gone, nil)
    }
}
