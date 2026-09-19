import Foundation

/// Ask claude itself whether it can start, and classify the answer.
///
/// TB launches claude. When a launch will not stay up, this runs the same
/// startup claude would run (settings, plugins, hooks, MCP) in one bounded
/// print-mode probe and reads the result, so the app can tell WHY without
/// anyone typing a command. Ruled 10 Sep (Robert): the user is non-technical,
/// so the app fixes what it safely can (see `ClaudeConfigRepair`) and logs the
/// classified verdict so we can tell for sure. Nothing here is shown to the
/// user as a command to run.
///
/// The probe is print mode on purpose: it exercises the whole config path (a
/// broken plugin, hook, or MCP cannot hide) without the interactive screen,
/// so it is deterministic and cannot itself hang on a TTY.
public enum ClaudeHealth {

    public struct Verdict: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            /// Startup reached the model and answered. Config is clean.
            case healthy
            /// No claude binary on PATH.
            case binaryMissing
            /// A plugin, hook, MCP, or config error aborted startup.
            case startupError
            /// Startup did not finish inside the deadline, a blocking step.
            case startupHang
        }
        public let kind: Kind
        /// One line for the log.
        public let summary: String
        /// The agent's own last words, scrubbed and bounded, as evidence.
        public let evidence: String

        public init(kind: Kind, summary: String, evidence: String) {
            self.kind = kind; self.summary = summary; self.evidence = evidence
        }
    }

    /// What the probe observed. Kept separate from `Verdict` so the decision is
    /// a pure function testable with no process.
    public enum StartupOutcome: Sendable, Equatable {
        case answered
        case failed(tail: String)
        case timedOut
        case binaryMissing
    }

    public static func classify(_ outcome: StartupOutcome) -> Verdict {
        switch outcome {
        case .binaryMissing:
            return Verdict(kind: .binaryMissing,
                           summary: "claude binary not found on PATH",
                           evidence: "")
        case .timedOut:
            return Verdict(kind: .startupHang,
                           summary: "claude startup did not finish in time; a plugin or MCP "
                               + "server is likely blocking it",
                           evidence: "")
        case .failed(let tail):
            return Verdict(kind: .startupError,
                           summary: "claude startup failed before it could answer; likely a "
                               + "plugin, hook, or MCP from a recent install",
                           evidence: TrustPromptWatcher.meaningfulTail(tail))
        case .answered:
            return Verdict(kind: .healthy,
                           summary: "claude started and answered; startup config is clean",
                           evidence: "")
        }
    }

    /// Runs the probe. `runner` returns the combined output or a failure, and
    /// is injected so a test needs no real claude.
    public typealias Runner = @Sendable (_ arguments: [String], _ timeout: TimeInterval)
        -> Result<String, ScriptError>

    public static func probe(runner: Runner, token: String = "tbhealthok",
                             timeout: TimeInterval = 45) -> Verdict {
        switch runner(["--debug", "-p", "reply with only this word: \(token)"], timeout) {
        case .success(let out):
            // Exit 0 but no token means a non-fatal fault swallowed the turn,
            // still a startup that could not do its one job.
            return classify(out.contains(token) ? .answered : .failed(tail: out))
        case .failure(let error):
            return classify(error.timedOut ? .timedOut : .failed(tail: error.message))
        }
    }

    /// The production runner: resolve the binary and PATH, run under a clean
    /// env with an empty stdin so `-p` never blocks waiting for input.
    public static func liveRunner(adapter: any HarnessAdapter = ClaudeCodeAdapter()) -> Runner {
        { arguments, timeout in
            guard let binary = ClaudeAgentsCLI.resolveBinary() else {
                return .failure(ScriptError(message: "claude binary not found"))
            }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = adapter.pathCandidates.joined(separator: ":")
            return Subprocess.run(binary, arguments, environment: env,
                                  stdin: Data(), timeout: timeout)
        }
    }

    /// The whole check, for the app: probe, then classify. Blocks on the
    /// subprocess; call off-main.
    public static func check(adapter: any HarnessAdapter = ClaudeCodeAdapter()) -> Verdict {
        guard ClaudeAgentsCLI.resolveBinary() != nil else {
            return classify(.binaryMissing)
        }
        return probe(runner: liveRunner(adapter: adapter))
    }
}
