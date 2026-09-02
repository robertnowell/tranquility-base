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

    /// ONE ROW PER HARNESS, not one row for "hooks".
    ///
    /// `hooks` was a single case, so a two-harness machine got a single row and
    /// a single lamp standing in for two installs that fail independently. The
    /// first version of this fix kept the row and split only the TEXT, which
    /// was what was asked for and is still not enough: most people run Claude
    /// Code or Codex, not both, and a conflated row hides the state of whichever
    /// one they actually use behind the state of the one they do not.
    ///
    /// Ruled 1 Sep: "one row per harness hooks." So the case carries the
    /// harness it is about, and the list of items is a function of what this
    /// machine has rather than a constant.
    ///
    /// Not `String`-backed any more, because a case with a payload cannot be.
    /// `id` replaces `rawValue` and is what button identifiers and logs use.
    public enum Item: Hashable, Sendable {
        /// The only reply transport since the 23 Aug single-transport cut.
        case tmux
        /// How a finished turn reaches this app at all, per harness. The
        /// payload is `HarnessAdapter.id`, so this never becomes a second
        /// vocabulary for the same thing.
        case hooks(harness: String)
        /// Spoken summaries. The product.
        case anthropicKey
        /// The voice. Falls back to the system voice, audibly.
        case elevenLabsKey
        /// The live transcript while you speak.
        case assemblyAIKey

        /// Stable, and stable across harnesses: "hooks.codex" is not
        /// "hooks.claude-code". Used for button identifiers and log lines.
        public var id: String {
            switch self {
            case .tmux: return "tmux"
            case .hooks(let harness): return "hooks." + harness
            case .anthropicKey: return "anthropicKey"
            case .elevenLabsKey: return "elevenLabsKey"
            case .assemblyAIKey: return "assemblyAIKey"
            }
        }

        public init?(id: String) {
            switch id {
            case "tmux": self = .tmux
            case "anthropicKey": self = .anthropicKey
            case "elevenLabsKey": self = .elevenLabsKey
            case "assemblyAIKey": self = .assemblyAIKey
            default:
                guard id.hasPrefix("hooks.") else { return nil }
                self = .hooks(harness: String(id.dropFirst("hooks.".count)))
            }
        }

        /// Which harness this row is about, or nil for the rows that are not
        /// about a harness at all.
        public var harness: HookManifest.Harness? {
            guard case .hooks(let id) = self else { return nil }
            return HookManifest.harnesses.first { $0.id == id }
        }

        public var title: String {
            switch self {
            case .tmux: return "tmux"
            // "Claude Code hooks", "Codex hooks". Naming the harness in the
            // row is the whole point of there being two of them.
            case .hooks: return (harness?.label ?? "Agent") + " hooks"
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
            // phrasing the onboarding body already uses. The currency sign is
            // also a MARK by `ChromeType.isMark`, and this row renders inside
            // the panel now that Settings hosts the same checklist, where the
            // `chrome` drill requires every mark to be composed. Composing a
            // symbol inside a prose sentence would be the wrong fix: chrome
            // composition is for chrome.
            case .anthropicKey: return "spoken summaries, about a tenth of a cent each"
            case .elevenLabsKey: return "the voice; without it, the system one"
            case .assemblyAIKey: return "the live transcript while you speak"
            }
        }

        /// tmux, the hooks, and the Anthropic key hold the gate.
        ///
        /// ANTHROPIC IS REQUIRED AS OF 1 SEP, and the argument is the product's
        /// own. Without that key the readout falls to `DeterministicSummarizer`,
        /// which reads back the opening of the agent's message and whose own
        /// comment calls it "a floor, not a product". Robert, having heard it:
        /// "without the Anthropic key you just get the whole readout, the last
        /// message. That's not good. That's not Tranquility Base." Shipping the
        /// floor as the default is shipping something that is not the thing.
        ///
        /// The other two stay optional, and that is the same decision made
        /// honestly rather than a failure to decide: ElevenLabs missing means
        /// the macOS system voice and AssemblyAI missing means transcription
        /// after you stop instead of during. Both are degraded and both still
        /// work. The Anthropic fallback does not.
        ///
        /// The hooks rows are required INDIVIDUALLY here but gated COLLECTIVELY
        /// by `allRequiredSatisfied`, which needs only one wired harness. See
        /// there for why.
        public var isRequired: Bool {
            switch self {
            case .tmux, .hooks, .anthropicKey: return true
            case .elevenLabsKey, .assemblyAIKey: return false
            }
        }

        /// Which keychain entry this row is about; nil for the ones that are
        /// not credentials at all.
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
            // One door, both harnesses. Installing IS a both thing (ruled
            // 1 Sep); only the reporting splits. Pressing it on either row
            // repairs every harness this machine has.
            case .hooks: return "Wire them"
            case .anthropicKey, .elevenLabsKey, .assemblyAIKey: return "Paste key"
            }
        }
    }

    /// The rows this machine has, in order.
    ///
    /// A function rather than `allCases`, because the hooks rows depend on which
    /// harnesses are installed. `detected()` is two `fileExists` calls, which is
    /// cheap enough to run while building the view: the expensive probes (the
    /// audit, the keychain, the login shell) stay in `snapshot`, off-main.
    ///
    /// A machine with no harness gets no hooks row, which is right. Telling
    /// somebody their Codex hooks are broken when they have never run Codex is
    /// the thing `Harness.isPresent` has always existed to prevent.
    public static func items() -> [Item] {
        [.tmux]
            + HookManifest.detected().map { Item.hooks(harness: $0.id) }
            + [.anthropicKey, .elevenLabsKey, .assemblyAIKey]
    }

    public struct State: Sendable, Equatable {
        public let item: Item
        public let satisfied: Bool
        /// Live status text, in the same register as `Permissions.statusDescription`.
        public let detail: String
        /// Unsatisfied AND the user's to fix now, as opposed to unsatisfied and
        /// merely absent. An optional row nobody has filled in is quiet; an
        /// optional row holding a credential the provider refused is not, and
        /// painting them the same colour is what let a rejected key sit under a
        /// green lamp. Defaulted so every existing construction is unchanged.
        public let attention: Bool

        public init(item: Item, satisfied: Bool, detail: String, attention: Bool = false) {
            self.item = item
            self.satisfied = satisfied
            self.detail = detail
            self.attention = attention
        }
    }

    /// Injected so the detectors are testable without a keychain, a real
    /// settings.json, or tmux on the machine running the tests.
    public struct Probes: Sendable {
        public var tmuxPath: @Sendable () -> String?
        /// nil when every hook is wired and reachable, matching `HookManifest`.
        /// What is wrong with ONE harness, by its id, or nil when nothing is.
        ///
        /// Was machine-wide, which is what forced one row to speak for two
        /// installs. A row per harness needs a probe per harness.
        public var hooksProblem: @Sendable (String) -> String?
        public var hasSecret: @Sendable (Secrets.Key) -> Bool
        /// What the provider last said about a stored key, or nil if it was
        /// never asked. A row that reports a refusal in its text and a green
        /// lamp beside it is the state this closes.
        public var keyVerdict: @Sendable (Secrets.Key) -> KeyCheck.Outcome?

        public init(
            tmuxPath: @escaping @Sendable () -> String?,
            hooksProblem: @escaping @Sendable (String) -> String?,
            hasSecret: @escaping @Sendable (Secrets.Key) -> Bool,
            keyVerdict: @escaping @Sendable (Secrets.Key) -> KeyCheck.Outcome? = { _ in nil }
        ) {
            self.tmuxPath = tmuxPath
            self.hooksProblem = hooksProblem
            self.hasSecret = hasSecret
            self.keyVerdict = keyVerdict
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
            hooksProblem: { id in
                HookManifest.harnesses.first { $0.id == id }
                    .flatMap { HookManifest.problem(for: $0) }
            },
            hasSecret: { Secrets.read($0) != nil },
            keyVerdict: { KeyVerdict.last(for: $0) })
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
        items().map { item in
            if let secret = item.secret {
                guard probes.hasSecret(secret) else {
                    return State(item: item, satisfied: false, detail: missingDetail(item))
                }
                // Stored is not working, and the difference is the whole reason
                // `KeyCheck` exists. A refusal is the one verdict that means the
                // thing the user just did did not take, so it costs the row its
                // lamp; everything else (checked and good, never checked, could
                // not be reached) leaves a stored key satisfied, because none of
                // them is evidence against it.
                guard let verdict = probes.keyVerdict(secret), verdict.isBad else {
                    return State(item: item, satisfied: true,
                                 detail: probes.keyVerdict(secret)?.summary ?? "in your keychain")
                }
                return State(item: item, satisfied: false,
                             detail: verdict.summary, attention: true)
            }
            switch item {
            case .tmux:
                if let path = probes.tmuxPath() {
                    return State(item: item, satisfied: true, detail: path)
                }
                return State(item: item, satisfied: false,
                             detail: "not installed. Replies have nowhere to go")
            case .hooks(let harnessID):
                // ONE harness, its own row, its own lamp.
                //
                // The first attempt at this kept a single row and split only
                // the text, which was the letter of the ruling and not enough:
                // most people run Claude Code or Codex, not both, so a row that
                // averages two harnesses hides the state of whichever one they
                // actually use behind the one they do not.
                //
                // The row is titled with the harness name, so the detail never
                // repeats it: "Codex hooks / installed, awaiting approval", not
                // "Codex hooks / Codex: installed, awaiting approval".
                if let problem = probes.hooksProblem(harnessID) {
                    return State(item: item, satisfied: false, detail: problem)
                }
                return State(item: item, satisfied: true, detail: "wired")
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

    /// The gate the Start door uses.
    ///
    /// tmux and the Anthropic key are each required outright. The hooks are
    /// required COLLECTIVELY: at least one harness has to be wired, and a
    /// second broken one does not hold the door.
    ///
    /// That distinction is the reason the rows split rather than a consequence
    /// of it. Most people run Claude Code or Codex, not both, so `detected()`
    /// will often find a harness whose config directory exists because it was
    /// tried once and abandoned. Demanding every one of those before first run
    /// can finish would block somebody on a tool they do not use, which is
    /// precisely the gauntlet this screen was cleared of on 1 Sep. An unused
    /// harness is allowed to sit amber: it says something true, and it stops
    /// nothing.
    ///
    /// A machine with no harness at all has no hooks rows and passes here,
    /// unchanged. There is nothing to wire, and inventing a blocker for it
    /// would be telling somebody their Codex is broken when they have never
    /// run Codex.
    public static func allRequiredSatisfied(_ states: [State]) -> Bool {
        var hooks: [State] = [], others: [State] = []
        for state in states {
            if case .hooks = state.item { hooks.append(state) }
            else if state.item.isRequired { others.append(state) }
        }
        guard others.allSatisfy(\.satisfied) else { return false }
        return hooks.isEmpty || hooks.contains(where: \.satisfied)
    }

    /// Rows worth drawing. All of them.
    ///
    /// `hooks` used to be hidden while healthy, on the argument that the app
    /// repairs at launch and a row reporting that nothing happened is
    /// furniture. REVERSED 1 Sep, by the only evidence that settles a question
    /// like this: somebody used it. Robert, on a fresh install, "the hooks
    /// don't show like success. And I wonder why."
    ///
    /// They did not show it because there was nothing left to show it with.
    /// Success removed the row, so the one line on the screen that could have
    /// said "Claude Code wired, Codex wired" was deleted at the exact moment it
    /// had something worth saying, and the checklist's answer to "is this part
    /// working" was a gap where a row used to be. A gap is not an answer; on a
    /// screen whose whole job is stating what is ready, it reads as the item
    /// having been dropped.
    ///
    /// This is the same ruling as the per-harness detail beside it and follows
    /// from it: a row told to report success separately for two harnesses has
    /// to be on screen to do it.
    public static func visible(_ states: [State]) -> [State] { states }
}
