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
        /// The cloud hub. Sign in once in the browser; the app keeps the token.
        case hub
        /// Summaries on us. The same sign-in; the row is where the standing
        /// lives and what the amber line opens. Ruled 15 Sep; the name is
        /// provisional.
        case credits
        /// Spoken summaries. The product.
        case anthropicKey
        /// The voice. Falls back to the system voice, audibly.
        case elevenLabsKey
        /// The live transcript while you speak.
        case assemblyAIKey
        /// Whisper, the durable transcript when streaming fails.
        ///
        /// MISSING UNTIL 13 SEP, and that omission is #326. `openAIAPIKey` had
        /// been in `Secrets.Key` for weeks, so every part of the app that USES
        /// it worked, and the only thing that did not exist was anywhere to
        /// type it. The root cause is worth stating because it is about to be
        /// repeated: this enum is hand-written and does NOT derive from
        /// `Secrets.Key.allCases`, so adding a credential is two edits and the
        /// second one has no compiler forcing it. `KeyCheck.request(for:)` is
        /// an exhaustive switch and therefore does force its half, which is
        /// exactly why that half was never missed.
        case openAIKey
        /// A cloud agent provider: one row per provider, carrying
        /// `AgentProvider.id`, the same way `hooks` carries `HarnessAdapter.id`
        /// rather than inventing a second vocabulary.
        case provider(id: String)

        /// Stable, and stable across harnesses: "hooks.codex" is not
        /// "hooks.claude-code". Used for button identifiers and log lines.
        public var id: String {
            switch self {
            case .tmux: return "tmux"
            case .hooks(let harness): return "hooks." + harness
            case .hub: return "hub"
            case .credits: return "credits"
            case .anthropicKey: return "anthropicKey"
            case .elevenLabsKey: return "elevenLabsKey"
            case .assemblyAIKey: return "assemblyAIKey"
            case .openAIKey: return "openAIKey"
            case .provider(let id): return "provider." + id
            }
        }

        public init?(id: String) {
            switch id {
            case "tmux": self = .tmux
            case "hub": self = .hub
            case "credits": self = .credits
            case "anthropicKey": self = .anthropicKey
            case "elevenLabsKey": self = .elevenLabsKey
            case "assemblyAIKey": self = .assemblyAIKey
            case "openAIKey": self = .openAIKey
            default:
                if id.hasPrefix("provider.") {
                    self = .provider(id: String(id.dropFirst("provider.".count)))
                    return
                }
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
            case .hub: return "Your hub"
            case .credits: return "Credits"
            case .anthropicKey: return "Anthropic"
            case .elevenLabsKey: return "ElevenLabs"
            case .assemblyAIKey: return "AssemblyAI"
            case .openAIKey: return "OpenAI"
            case .provider(let id): return Secrets.credential(forProvider: id)?.provider ?? id
            }
        }

        /// What it buys, in the register of the permission rows: what breaks
        /// without it, never what it is.
        public var why: String {
            switch self {
            case .tmux: return "the only way a reply reaches a session"
            case .hooks: return "finished turns, and results as pages you can open"
            case .hub: return "everything your agents write, in one place, on every device"
            case .credits: return "spoken summaries on us, ten dollars to start, with the same sign-in"
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
            case .openAIKey: return "the transcript that survives a streaming failure"
            case .provider: return "that provider's agents, as rows you can answer"
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
            // The hub joined the required rows on 13 Sep, when the connect
            // flow landed and a new machine could finally satisfy it by
            // pressing the button on the row. Before that it was optional for
            // an honest reason: nothing on this screen could make it green.
            case .tmux, .hooks, .anthropicKey, .hub: return true
            // OpenAI and the providers are optional for the same honest reason
            // ElevenLabs is: without OpenAI a streaming failure costs the
            // transcript rather than the app, and a machine that drives no
            // cloud provider is a machine using the product as it has always
            // worked. Neither one is the Anthropic case, where the fallback is
            // "a floor, not a product".
            // Credits are optional for the same reason: a Mac on its own key
            // is a Mac using the product as it always has. The row's amber
            // is about a Mac that WAS on credits and fell off them.
            case .elevenLabsKey, .assemblyAIKey, .openAIKey, .provider, .credits: return false
            }
        }

        /// Which keychain entry this row is about; nil for the ones that are
        /// not credentials at all.
        public var secret: Secrets.Key? {
            switch self {
            case .tmux, .hooks, .hub, .credits: return nil
            case .anthropicKey: return .anthropicAPIKey
            case .elevenLabsKey: return .elevenLabsAPIKey
            case .assemblyAIKey: return .assemblyAIAPIKey
            case .openAIKey: return .openAIAPIKey
            case .provider(let id): return Secrets.credential(forProvider: id)
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
            case .hub, .credits: return "Sign in"
            case .anthropicKey, .elevenLabsKey, .assemblyAIKey, .openAIKey,
                 .provider: return "Paste key"
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
    /// INJECTABLE, and it has to be. The first version read `detected()`
    /// directly, which made every hooks test depend on the machine running it
    /// having `~/.claude`: green here, and a force-unwrap crash on CI, where no
    /// harness exists and the row the test asked for was simply not there. A
    /// test that only passes on the developer's Mac is the same defect as the
    /// path that only breaks off it, which is what this whole branch is about.
    /// **`providers` defaults to NONE CONFIGURED, not to reading the disk**, and
    /// that asymmetry with `harnesses` is deliberate. It was the other way on
    /// 13 Sep and it broke the suite the moment a provider was configured on a
    /// real machine: `snapshot` builds rows from `Probes.providers`, which
    /// correctly defaults to empty, while this defaulted to the live
    /// `hq.json`, so the two disagreed about how many rows exist and every
    /// test that looked a row up in the snapshot crashed on a nil.
    ///
    /// CI could never have caught it. CI has no `~/.claude/hq.json` with a
    /// provider in it, so the two defaults agreed there and disagreed only on
    /// the one machine that had finished the setup this code exists to
    /// support. Use `live()` where the real answer is wanted.
    public static func items(
        harnesses: [String] = HookManifest.detected().map(\.id),
        providers: [String] = []
    ) -> [Item] {
        [.tmux]
            + harnesses.map { Item.hooks(harness: $0) }
            + [.hub, .credits, .anthropicKey, .elevenLabsKey, .assemblyAIKey, .openAIKey]
            // A provider gets a row once this machine has an ADDRESS for it,
            // the same way a harness gets a hooks row once it is detected.
            // Listing every provider the app can drive would tell someone
            // their crobot credential is missing on a machine that has never
            // heard of crobot, which is what `Harness.isPresent` has always
            // existed to prevent.
            // A provider with no KNOWN CREDENTIAL gets no row. Its `secret` is
            // nil, so `promptForKey` would return silently and the row would
            // render a "Paste key" button that does nothing at all: the one
            // outcome worse than no row, because it looks like a thing you can
            // fix. `Secrets.credential(forProvider:)` is the single place that
            // mapping lives, so this cannot drift from what the sheet can open.
            + providers.filter { Secrets.credential(forProvider: $0) != nil }
                .map { Item.provider(id: $0) }
    }

    /// The rows THIS machine has, asking the machine.
    ///
    /// One accessor rather than a parameter every call site has to remember,
    /// for the reason `GridAssembler.tabDisplayName` records at length: a
    /// parameter is a thing a call site can forget, and the forgetting is
    /// invisible. Three places render or count these rows, and a provider row
    /// missing from one of them is a checklist that disagrees with itself.
    public static func live() -> [Item] {
        items(harnesses: HookManifest.detected().map(\.id),
              providers: ProviderConfig.configured())
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
    /// What this Mac's hub connection amounts to: whether it is connected,
    /// and the one line the row prints. Two fields rather than one string,
    /// because "connected as mini, synced 2m ago" and "mini, not connected:
    /// this Mac's key was revoked" are both details and only one of them is a
    /// green lamp.
    public struct HubState: Sendable, Equatable {
        public var connected: Bool
        public var detail: String
        public init(connected: Bool, detail: String) {
            self.connected = connected; self.detail = detail
        }
    }

    public struct Probes: Sendable {
        public var tmuxPath: @Sendable () -> String?
        /// nil when every hook is wired and reachable, matching `HookManifest`.
        /// What is wrong with ONE harness, by its id, or nil when nothing is.
        ///
        /// Was machine-wide, which is what forced one row to speak for two
        /// installs. A row per harness needs a probe per harness.
        public var hooksProblem: @Sendable (String) -> String?
        /// Which harnesses this machine has, by id. A probe like any other:
        /// "what is installed" is exactly the kind of question a test needs to
        /// answer for itself.
        public var harnesses: @Sendable () -> [String]
        /// Which cloud providers this machine has an ADDRESS for, by
        /// `AgentProvider.id`. A probe for the same reason `harnesses` is one.
        ///
        /// Added 13 Sep because it was missing, and missing here does not fail
        /// loudly: `items(harnesses:providers:)` defaults `providers` to
        /// `ProviderConfig.configured()`, and `snapshot` passed `harnesses:`
        /// and not `providers:`, so half the rows read the real `~/.claude/hq.json`
        /// straight through the seam built to stop exactly that. The demo
        /// mode's own comment says it "reads nothing, writes nothing"; it read.
        public var providers: @Sendable () -> [String]
        public var hasSecret: @Sendable (Secrets.Key) -> Bool
        /// What the provider last said about a stored key, or nil if it was
        /// never asked. A row that reports a refusal in its text and a green
        /// lamp beside it is the state this closes.
        public var keyVerdict: @Sendable (Secrets.Key) -> KeyCheck.Outcome?
        /// The hub's state for this Mac, or nil when it has never been
        /// connected. `connected` is separate from the text because a Mac
        /// whose key was revoked has plenty to say and is not connected: one
        /// string cannot carry both, and when it tried, a revoked token kept
        /// a green lamp.
        public var hubStatus: @Sendable () -> HubState? = { nil }
        /// Where this Mac stands with credits. The live value is the one
        /// standing the summariser keeps; tests hand in whichever they mean.
        public var creditStanding: @Sendable () -> CreditStanding = { .notOnCredits(connectAgain: false) }

        public init(
            tmuxPath: @escaping @Sendable () -> String?,
            hooksProblem: @escaping @Sendable (String) -> String?,
            hasSecret: @escaping @Sendable (Secrets.Key) -> Bool,
            keyVerdict: @escaping @Sendable (Secrets.Key) -> KeyCheck.Outcome? = { _ in nil },
            harnesses: @escaping @Sendable () -> [String]
                = { HookManifest.detected().map(\.id) },
            // Defaults to NOTHING CONFIGURED, not to reading the disk. A test
            // that forgets this gets a machine with no providers, which is a
            // deterministic answer; defaulting it to `ProviderConfig.configured()`
            // would reintroduce exactly the bypass this field exists to close.
            providers: @escaping @Sendable () -> [String] = { [] },
            hubStatus: @escaping @Sendable () -> HubState? = { nil },
            creditStanding: @escaping @Sendable () -> CreditStanding = { .notOnCredits(connectAgain: false) }
        ) {
            self.tmuxPath = tmuxPath
            self.providers = providers
            self.hooksProblem = hooksProblem
            self.harnesses = harnesses
            self.hasSecret = hasSecret
            self.keyVerdict = keyVerdict
            self.hubStatus = hubStatus
            self.creditStanding = creditStanding
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
            keyVerdict: { KeyVerdict.last(for: $0) },
            // The live value reads the config; every other Probes does not,
            // because the parameter defaults to none configured.
            providers: { ProviderConfig.configured() },
            hubStatus: {
                guard HubApp.baseURL != nil, Secrets.read(.hubToken) != nil else { return nil }
                let device = HubMirror.deviceName()
                guard let beat = HubMirror.shared?.lastHeartbeat else {
                    return HubState(connected: true, detail: "connected as \(device)")
                }
                let ago = Int(Date().timeIntervalSince(beat.at) / 60)
                let when = ago < 1 ? "just now" : "\(ago)m ago"
                if beat.note.hasPrefix("ok") {
                    return HubState(connected: true, detail: "connected as \(device) · synced \(when)")
                }
                // The mirror's own words. "not connected" in the note is the
                // hub having refused this Mac's key, which is a red row with
                // the button back, not a green one with bad news in the text.
                return HubState(connected: !beat.note.hasPrefix("not connected"),
                                detail: "\(device) · \(beat.note)")
            },
            creditStanding: { CreditStanding.current })
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
        let credits = probes.creditStanding()
        return items(harnesses: probes.harnesses(), providers: probes.providers()).map { item in
            if item == .anthropicKey, credits.isOnCredits, !probes.hasSecret(.anthropicAPIKey) {
                return State(item: item, satisfied: true,
                             detail: "not required for credits · optional for direct use")
            }
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
            case .hub:
                if let hub = probes.hubStatus() {
                    return State(item: item, satisfied: hub.connected, detail: hub.detail,
                                 attention: !hub.connected)
                }
                return State(item: item, satisfied: false,
                             detail: "not connected. Sign in and your agents' pages and turns appear in the hub")
            case .credits:
                let standing = credits
                let ownKey = probes.hasSecret(.anthropicAPIKey)
                if standing.isOnCredits {
                    return State(item: item, satisfied: true, detail: standing.detail(ownKey: ownKey))
                }
                return State(item: item, satisfied: false, detail: standing.detail(ownKey: ownKey),
                             attention: standing.needsAttention(ownKey: ownKey))
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
        case .openAIKey: return "without it, a streaming failure loses the transcript"
        case .provider: return "without it, that provider's agents do not appear"
        // `missing` is the last resort and it is deliberately NOT reachable for
        // a credential row: `testEveryMissingKeyNamesWhatIsLost` walks every
        // row with a secret and refuses a bare word, which is how the two rows
        // added on 13 Sep were caught before they shipped.
        default: return "missing"
        }
    }

    /// The gate the Start door uses.
    ///
    /// tmux is required; summaries need either verified managed readiness or
    /// the direct key. A stored Hub token alone is not readiness. The hooks are
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
        let managedReady = states.contains { $0.item == .credits && $0.satisfied }
        for state in states {
            if case .hooks = state.item { hooks.append(state) }
            else if state.item == .anthropicKey && managedReady { continue }
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
