import Foundation

/// What a terminal AI harness is, as a set of facts rather than a name.
///
/// Milestone 2 of the arc: the coupling map the 19 Aug audit drew (Claude
/// Code's resume flag written twice, its trust needles watched by two
/// hand-copied loops, one for each transport) collapses into this. The
/// protocol is deliberately small and deliberately explicit about variance —
/// the multi-harness survey's one documented regret (Happy's
/// `respondToPermission`, one method silently meaning different things per
/// backend) is the shape every capability here is written to avoid: each
/// value is a fact about ONE harness, named for what it is, not inferred.
public protocol HarnessAdapter: Sendable {
    /// Stable, human-legible: "claude-code", "codex". Persisted nowhere yet;
    /// exists so a log line or a card can say which harness it means.
    var id: String { get }

    /// The command a launcher runs, and how it appends a resume target.
    /// A FUNCTION, not a string suffix: Claude Code resumes with a flag
    /// (`--resume <id>`), Codex with a subcommand (`resume <id>`), and a
    /// suffix string cannot represent that difference — the exact shape the
    /// audit flagged when it found `resumeSuffix()` written once in
    /// `AgentDefaults` and the literal `["--resume", sessionId]` written
    /// again, independently, in `SessionDiscovery.reviveCommand`.
    func resumeArguments(sessionId: String) -> [String]

    /// The directory-trust prompt this harness's TUI shows on an unfamiliar
    /// cwd, if it has one — nil skips the watcher entirely rather than
    /// polling for needles that will never appear.
    var trustPrompt: TrustPromptSpec? { get }

    /// Facts about the TUI a launcher/transport needs and must never guess:
    /// does pasted text echo into a visible composer line, what glyph marks
    /// the composer's own line, does the harness queue typed input while
    /// mid-turn rather than reject it, does it register with a liveness
    /// probe TB can poll, does it have a hook system TB's intake can lean
    /// on. NOT YET CONSUMED (M2 gate finding, honest as of this milestone):
    /// TmuxTransport's landing check still hardcodes its own "every target
    /// echoes" belief rather than reading `echoesPaste` per target, because
    /// `DispatchTarget` carries no adapter reference yet. A parity test
    /// (`HarnessAdapterTests.testClaudeCodeEchoesPasteMatchesWhatTmuxTransportAssumes`)
    /// pins the two together until the wiring itself lands — presumably M3,
    /// alongside the per-target harness selection the transcript-parser
    /// collapse needs anyway.
    var capabilities: HarnessCapabilities { get }
}

public struct HarnessCapabilities: Sendable {
    public var echoesPaste: Bool
    public var promptGlyph: String
    public var queuesInputMidTurn: Bool
    public var registersWithLiveness: Bool
    public var hasHooks: Bool

    public init(echoesPaste: Bool, promptGlyph: String, queuesInputMidTurn: Bool,
               registersWithLiveness: Bool, hasHooks: Bool) {
        self.echoesPaste = echoesPaste
        self.promptGlyph = promptGlyph
        self.queuesInputMidTurn = queuesInputMidTurn
        self.registersWithLiveness = registersWithLiveness
        self.hasHooks = hasHooks
    }
}

/// What a launcher's trust watcher looks for and how it answers.
///
/// One generic loop (`TrustPromptWatcher.watch`) reads this instead of two
/// hand-copied 40-line loops (one per transport) each carrying the same
/// needles by hand. Needles are matched by substring, not regex: both
/// existing watchers already worked this way and neither ever needed more.
public struct TrustPromptSpec: Sendable {
    /// Any one of these appearing means the prompt is up.
    public var promptNeedles: [String]
    /// Seeing this means the TUI started with NOTHING to accept — stop
    /// watching immediately (Claude Code's "? for shortcuts" hint line).
    public var startedWithNoPromptNeedle: String?
    /// Seeing this twice in a row (banner settled) with no prompt needle
    /// means the same thing, less specifically — the fallback sentinel.
    public var settledBannerNeedle: String
    /// Consecutive settled-banner sightings required before giving up on a
    /// prompt ever appearing.
    public var settledThreshold: Int

    public init(promptNeedles: [String], startedWithNoPromptNeedle: String?,
               settledBannerNeedle: String, settledThreshold: Int = 2) {
        self.promptNeedles = promptNeedles
        self.startedWithNoPromptNeedle = startedWithNoPromptNeedle
        self.settledBannerNeedle = settledBannerNeedle
        self.settledThreshold = settledThreshold
    }
}

/// Claude Code, as a HarnessAdapter. The facts here are measurements, not
/// defaults: needles verified live 19 Aug against a real trust prompt
/// (`SessionLauncher.watchForTrustPrompt`), echo verified live 19 Aug on the
/// tmux composer, resume flag unchanged from `AgentDefaults.resumeSuffix()`.
public struct ClaudeCodeAdapter: HarnessAdapter {
    public let id = "claude-code"

    public init() {}

    public func resumeArguments(sessionId: String) -> [String] {
        ["--resume", sessionId]
    }

    public var trustPrompt: TrustPromptSpec? {
        TrustPromptSpec(
            promptNeedles: ["trust this folder", "Do you trust"],
            startedWithNoPromptNeedle: "? for shortcuts",
            settledBannerNeedle: "Claude")
    }

    public var capabilities: HarnessCapabilities {
        HarnessCapabilities(echoesPaste: true, promptGlyph: "❯",
                            queuesInputMidTurn: true, registersWithLiveness: true,
                            hasHooks: true)
    }
}

/// The one trust-prompt loop, parameterized by how to read a screen and how
/// to press Return — the two primitives that used to be the entire
/// difference between the AppleScript watcher and the tmux watcher. Both now
/// call this with their own `read`/`press`, and a `TrustPromptSpec` supplies
/// every needle. `nil` spec (a harness with no trust prompt) never calls in.
public enum TrustPromptWatcher {
    /// `pollInterval` is injectable (M2 gate finding): a test proving control
    /// flow ("accept on the needle", "stand down on the sentinel") does not
    /// need to pay the real 2s-per-poll wall-clock cost this loop uses live —
    /// three such tests once cost ~10s of `swift test` for zero additional
    /// evidence.
    public static func watch(
        spec: TrustPromptSpec,
        read: () -> String?,
        press: () -> Void,
        trace: (@Sendable (String) -> Void)? = nil,
        label: String = "",
        pollInterval: TimeInterval = 2.0,
        maxPolls: Int = 15
    ) {
        var settled = 0
        for _ in 0..<maxPolls {
            usleep(UInt32(pollInterval * 1_000_000))
            guard let text = read() else { continue }
            if spec.promptNeedles.contains(where: { text.contains($0) }) {
                press()
                trace?("newSession: accepted the trust prompt in \(label) — user-commanded launch")
                return
            }
            if let noPrompt = spec.startedWithNoPromptNeedle, text.contains(noPrompt) {
                return
            }
            if text.contains(spec.settledBannerNeedle) { settled += 1 } else { settled = 0 }
            if settled >= spec.settledThreshold {
                trace?("newSession: started with no trust prompt in \(label); watcher done")
                return
            }
        }
        let waited = Int(pollInterval * Double(maxPolls))
        trace?("newSession: no trust prompt seen in \(label) within \(waited)s; leaving it be")
    }
}
