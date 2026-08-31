import Foundation

/// What the loop needs from this Mac, once macOS has stopped asking questions.
///
/// The second half of first run, and the half that was invisible. Permissions
/// were always on screen; the things the loop actually RUNS on were not. Someone
/// could grant all four, watch every lamp go green, and own an app that could not
/// deliver a single reply, because tmux was missing and the only symptom was a
/// per-session error reading "tmux is unavailable for this session" -- which
/// names the session, not the machine.
///
/// Deliberately not part of `Permissions`, though the two are drawn alike. A TCC
/// permission has a Settings pane, a system prompt, and an answer macOS owns; the
/// app can only ask. None of these have that. Their fixes are a Homebrew command,
/// a call into `HookManifest`, and a text field. Folding them into
/// `Permissions.Kind` would hand each one a meaningless `settingsURL` and a
/// `request()` that cannot prompt, which is where an abstraction starts lying
/// about what it models.
///
/// Named `Prerequisites` because `Readiness` was already taken by a different
/// question: whether one SESSION can be typed into right now. This asks whether
/// the machine can run the loop at all.
public enum Prerequisites {

    public enum Item: String, Sendable, CaseIterable {
        /// The only reply transport since the 23 Aug single-transport cut.
        case tmux
        /// How a finished turn reaches this app at all.
        case hooks
        /// Spoken summaries. The product.
        case anthropicKey
        /// The voice. Falls back to the system voice, audibly.
        case elevenLabsKey
        /// The live transcript while you speak.
        case assemblyAIKey

        public var title: String {
            switch self {
            case .tmux: return "tmux"
            case .hooks: return "Agent hooks"
            case .anthropicKey: return "Anthropic"
            case .elevenLabsKey: return "ElevenLabs"
            case .assemblyAIKey: return "AssemblyAI"
            }
        }

        /// What it buys, in the register of the permission rows: what breaks
        /// without it, never what it is.
        public var why: String {
            switch self {
            case .tmux: return "the only way a reply reaches a session"
            case .hooks: return "finished turns, and results as pages you can open"
            // "a tenth of a cent", not "$0.001". Same number, and it is the
            // phrasing the onboarding body already uses two paragraphs down.
            // The currency sign is also a MARK by `ChromeType.isMark`, and this
            // row renders inside the panel now that Settings hosts the same
            // checklist, where the `chrome` drill requires every mark to be
            // composed. Composing a symbol inside a prose sentence would be the
            // wrong fix: chrome composition is for chrome.
            case .anthropicKey: return "spoken summaries, about a tenth of a cent each"
            case .elevenLabsKey: return "the voice; without it, the system one"
            case .assemblyAIKey: return "the live transcript while you speak"
            }
        }

        /// Only tmux and hooks hold the gate.
        ///
        /// The keys are RECOMMENDED, not required, and the distinction is the
        /// point of having one. Blocking on a key that only degrades trains
        /// people to click past a checklist; staying silent about one is how
        /// somebody ends up judging the product by `DeterministicSummarizer`,
        /// which reads back the opening of the agent's own message and is
        /// explicitly "a floor, not a product". Neither mistake is recoverable
        /// by adding more text later.
        public var isRequired: Bool {
            switch self {
            case .tmux, .hooks: return true
            case .anthropicKey, .elevenLabsKey, .assemblyAIKey: return false
            }
        }

        /// The one whose absence costs the most. Said out loud in the row rather
        /// than left for the user to infer from three identically-styled lines.
        public var isRecommended: Bool { self == .anthropicKey }

        /// Which keychain entry this row is about; nil for the two that are not
        /// credentials at all.
        public var secret: Secrets.Key? {
            switch self {
            case .tmux, .hooks: return nil
            case .anthropicKey: return .anthropicAPIKey
            case .elevenLabsKey: return .elevenLabsAPIKey
            case .assemblyAIKey: return .assemblyAIAPIKey
            }
        }

        /// Where the key actually comes from.
        ///
        /// A row that says "add a key" and does not say where to get one has
        /// handed the user a search, which is the thing this whole screen exists
        /// to stop doing. Verified to resolve 26 Aug.
        public var signupURL: URL? { secret?.consoleURL }

        /// What the fix button says. Core names it so the view cannot drift from
        /// it and a test can assert on it.
        public var fixLabel: String {
            switch self {
            case .tmux: return "Copy command"
            case .hooks: return "Wire them"
            case .anthropicKey, .elevenLabsKey, .assemblyAIKey: return "Paste key"
            }
        }
    }

    public struct State: Sendable, Equatable {
        public let item: Item
        public let satisfied: Bool
        /// Live status text, in the same register as `Permissions.statusDescription`.
        public let detail: String

        public init(item: Item, satisfied: Bool, detail: String) {
            self.item = item
            self.satisfied = satisfied
            self.detail = detail
        }
    }

    /// Injected so the detectors are testable without a keychain, a real
    /// settings.json, or tmux on the machine running the tests.
    public struct Probes: Sendable {
        public var tmuxPath: @Sendable () -> String?
        /// nil when every hook is wired and reachable, matching `HookManifest`.
        public var hooksProblem: @Sendable () -> String?
        public var hasSecret: @Sendable (Secrets.Key) -> Bool

        public init(
            tmuxPath: @escaping @Sendable () -> String?,
            hooksProblem: @escaping @Sendable () -> String?,
            hasSecret: @escaping @Sendable (Secrets.Key) -> Bool
        ) {
            self.tmuxPath = tmuxPath
            self.hooksProblem = hooksProblem
            self.hasSecret = hasSecret
        }

        public static let live = Probes(
            tmuxPath: {
                // The memo first: authoritative when it found something,
                // including in places only a login shell knows about.
                if let cached = Tmux.resolveBinary() { return cached }
                // It found nothing, but "nothing" may be a nil cached before the
                // user ran the command this very row told them to run.
                guard let fresh = tmuxOnDisk() else { return nil }
                // It is there now. Drop the memo, or the row goes green off this
                // scan while dispatch keeps refusing from the stale nil: one
                // machine, two answers, and the visible one wrong.
                Tmux.forgetBinary()
                return fresh
            },
            // EVERY harness this machine has, not just Claude Code.
            // `problemSummary()` audits one hardcoded file, which is how a
            // green checklist coexisted with Codex sessions that had no
            // hooks at all: the row was telling the truth about the only
            // harness it knew to ask about.
            hooksProblem: { HookManifest.machineSummary() },
            hasSecret: { Secrets.read($0) != nil })
    }

    /// The canonical install locations, checked WITHOUT `Tmux.resolveBinary`'s memo.
    ///
    /// That memo caches a MISS for the life of the process, a stated trade ("a
    /// binary that appears later costs one relaunch") that is right for the
    /// dispatch path and exactly wrong for a row whose whole job is to go green
    /// the moment the user runs the command it just handed them. So this rescans,
    /// but only the three cheap `isExecutableFile` checks and never the login
    /// shell, which has taken seconds. Those three are where `brew install tmux`
    /// puts it on Apple silicon and on Intel, which is the case the row guides.
    public static func tmuxOnDisk() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Read every dependency once.
    ///
    /// `nonisolated` and safe off the main actor, and it MUST be by rule 9: a
    /// hooks audit parses a file, a keychain read is a round trip, and the tmux
    /// fallback spawns a login shell. None of that belongs on a 1 Hz UI timer.
    public static func snapshot(_ probes: Probes = .live) -> [State] {
        Item.allCases.map { item in
            if let secret = item.secret {
                return probes.hasSecret(secret)
                    ? State(item: item, satisfied: true, detail: "in your keychain")
                    : State(item: item, satisfied: false, detail: missingDetail(item))
            }
            switch item {
            case .tmux:
                if let path = probes.tmuxPath() {
                    return State(item: item, satisfied: true, detail: path)
                }
                return State(item: item, satisfied: false,
                             detail: "not installed. Replies have nowhere to go")
            case .hooks:
                if let problem = probes.hooksProblem() {
                    // problemSummary says "hooks: 2 not installed" because it
                    // also feeds a log line; in a row already labelled "Claude
                    // Code hooks" that prefix is said twice.
                    let trimmed = problem.hasPrefix("hooks: ")
                        ? String(problem.dropFirst("hooks: ".count)) : problem
                    return State(item: item, satisfied: false, detail: trimmed)
                }
                // Name every harness it is wired into, not the first one we
                // happened to support. On a machine running both, "wired into
                // Claude Code" is a true sentence that answers the wrong
                // question: the reason this row exists on a two-harness machine
                // is to say whether CODEX is covered too (Robert, 30 Aug,
                // looking at exactly that line).
                let harnesses = HookManifest.detected().map(\.label)
                return State(item: item, satisfied: true,
                             detail: harnesses.isEmpty
                                ? "wired"
                                // "and", not "+". A plus sign is a SYMBOL, so
                                // `ChromeType.isMark` counts it, and this
                                // string renders inside the panel where the
                                // chrome drill requires every mark to be
                                // composed. Same trap as the currency sign on
                                // 30 Aug; composing a connective inside a
                                // prose sentence is still the wrong fix.
                                : "wired into " + harnesses.joined(separator: " and "))
            default:
                return State(item: item, satisfied: true, detail: "")
            }
        }
    }

    /// What is lost, per key. Never a bare "missing": the row has to be worth
    /// reading by someone deciding whether to go and get one.
    private static func missingDetail(_ item: Item) -> String {
        switch item {
        case .anthropicKey: return "without it, a plain first-sentence readout"
        case .elevenLabsKey: return "without it, the macOS system voice"
        case .assemblyAIKey: return "without it, transcription after you stop"
        default: return "missing"
        }
    }

    /// The gate the Start door uses. Required rows only.
    public static func allRequiredSatisfied(_ states: [State]) -> Bool {
        states.filter(\.item.isRequired).allSatisfy(\.satisfied)
    }

    /// Rows worth drawing.
    ///
    /// `hooks` is hidden while healthy. The app repairs hooks at launch and says
    /// so in the HUD, so in the normal case a row for them is a line of furniture
    /// reporting that nothing happened. It appears only when repair could not
    /// finish, which is the one time the user needs a door.
    public static func visible(_ states: [State]) -> [State] {
        states.filter { $0.item != .hooks || !$0.satisfied }
    }
}
