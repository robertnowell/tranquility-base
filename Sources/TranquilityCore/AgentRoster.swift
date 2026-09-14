import Foundation

/// **Every agent Tranquility Base will actually offer you**, and what, if
/// anything, stands between you and using it.
///
/// Ruled 14 Sep 2026, correcting three mistakes in a first design:
///
/// 1. **Proving that an agent works at all is OUR job, not the user's.**
///    *"It's up to us to make sure that all the agents are working. That's
///    development, that's not usage."* The expensive readiness probe — driving
///    a real prompt turn to see whether the protocol still behaves — lives in
///    the test suite and runs on our machines. It is not a button anybody is
///    offered, and there is no sweep across the roster.
///
/// 2. **A signed-out user is not a broken app.** *"If the user is not signed
///    in, that's fine. Like, have them sign in. You just need to detect that
///    they need to sign in."* So being signed out is an ordinary state with an
///    ordinary next step, never an error and never a block.
///
/// 3. **Only agents we have fully validated appear here at all.** *"The only
///    things that should be in the grid are ones that we've fully validated
///    and tested and love and work with."* This is not the ACP catalog. The
///    catalog is a list of published claims about other people's software and
///    lives in `ACPCatalog`; this is the shortlist we stand behind.
public struct AgentRoster: Sendable {

    /// What stands between the user and using this agent. Deliberately three
    /// cases and not a status string: a tile shows a tick or it does not, and
    /// anything else is a sentence somebody has to write and translate.
    public enum Standing: Sendable, Equatable {
        /// A tick. Installed, credentialed, ready to pick.
        case ready
        /// Greyed, with a next step. The agent is here but the user is not
        /// signed in, or it is not installed yet.
        case needsSetup(Step)
        /// Greyed, and the step is somebody else's: we have not finished
        /// validating this one, so it is not offered.
        case notOffered

        public var isReady: Bool { self == .ready }
    }

    /// The one thing a tap has to do. Each carries the words the vendor itself
    /// uses where we have them, because `ACPWire.Initialized.authMethods` says
    /// it better than we can and stays right when they change it.
    public enum Step: Sendable, Equatable {
        /// Not on this machine. Carries how to get it.
        case install(String)
        /// Here, but signed out. Carries the agent's own instruction, e.g.
        /// "Run `opencode auth login` in the terminal".
        case signIn(String)
        /// Here and signed in, but we have no credential for the service it
        /// talks to. crobot's API key is this.
        case addCredential(String)
    }

    public struct Agent: Sendable, Equatable, Identifiable {
        public let id: String
        /// What a person calls it. The tile shows this and nothing else.
        public let name: String
        /// A glyph, so the grid reads at a glance rather than by reading.
        public let glyph: String
        public let standing: Standing

        public init(id: String, name: String, glyph: String, standing: Standing) {
            self.id = id
            self.name = name
            self.glyph = glyph
            self.standing = standing
        }
    }

    // MARK: - The shortlist

    /// **Validated by us, on a real machine, end to end.** An entry earns its
    /// place by having been driven through a whole turn and doing the work,
    /// not by appearing in somebody's published catalog.
    ///
    /// Adding one is deliberately a code change with a date and a witness
    /// attached, because that is the whole point: *"the only things that
    /// should be in the grid are ones that we've fully validated and tested
    /// and love and work with."*
    /// How far an agent gets from inside the app, which is a different
    /// question from whether its protocol works.
    public enum Reach: Sendable, Equatable {
        /// Pick it, drive it, reply to it, start a new one.
        case whole
        /// It appears and can be opened, but this app cannot yet drive it.
        case readOnly
        /// The protocol is proven and nothing in the app is wired to it.
        case protocolOnly

        /// **Only `whole` may be offered as a choice.** Anything less would
        /// put a tile in front of the user that signs them in and then cannot
        /// use what they signed into.
        public var isOfferable: Bool { self == .whole }
    }

    public struct Validated: Sendable {
        public let id: String
        public let name: String
        public let glyph: String
        /// When, and by what evidence. Prose, read by people, so that a row
        /// nobody can vouch for any more is obvious on sight.
        public let provenance: String
        /// How far this agent actually gets from inside the app today.
        public let reach: Reach

        public init(id: String, name: String, glyph: String,
                    provenance: String, reach: Reach) {
            self.id = id; self.name = name; self.glyph = glyph
            self.provenance = provenance; self.reach = reach
        }
    }

    /// **`provenance` states what was PROVEN, and `reach` states how far it
    /// gets from the app.** They are different questions and the first draft
    /// of this list conflated them, which is how "reply delivered through the
    /// spool" came to be written about a reply that has only ever reached a
    /// test double. Protocol-level validation is not end-to-end reach, and a
    /// tile that implies otherwise is a promise this app cannot keep.
    public static let validated: [Validated] = [
        .init(id: "claude-code", name: "Claude Code", glyph: "✳",
              provenance: "The original harness. In daily use since the first build.",
              reach: .whole),
        .init(id: "codex", name: "Codex", glyph: "◆",
              provenance: "Second harness, shipped 4 Sep 2026. In daily use.",
              reach: .whole),
        .init(id: "crobot", name: "crobot", glyph: "◇",
              provenance: "13 Sep 2026: live gateway, 115 tasks filtered to the 1 that is "
                        + "mine, row drawn green, its page opens. Sending has been driven "
                        + "against a fake gateway only — never against the live one.",
              reach: .readOnly),
        .init(id: "opencode", name: "OpenCode", glyph: "○",
              provenance: "14 Sep 2026: over ACP it edited a file on disk "
                        + "(print('hello') -> print('goodbye')) through tool calls. The "
                        + "app reaches it over HTTP; the ACP path is not registered.",
              reach: .readOnly),
        .init(id: "devin", name: "Devin", glyph: "▲",
              provenance: "14 Sep 2026: ACP handshake, session and a whole prompt turn, "
                        + "with no code changes beyond the catalog row. Proven at the "
                        + "protocol only — ACPProvider is registered nowhere.",
              reach: .protocolOnly),
    ]

    // MARK: - Assembling the grid

    /// The tiles, in one pass.
    ///
    /// Everything expensive is OUT of this function by design: it reads what is
    /// on disk and what credentials exist, and nothing else. Whether an agent's
    /// login has expired is NOT asked here — that answer costs a model call,
    /// and asking eight of them to paint a settings panel would be absurd.
    /// It is discovered the moment the user actually uses the agent, which is
    /// the only time it matters and the only time it is free.
    public static func grid(
        installed: (String) -> Bool,
        credentialed: (String) -> Bool,
        signedOut: Set<String> = [],
        instructions: [String: Step] = [:]
    ) -> [Agent] {
        validated.map { entry in
            let standing: Standing
            if !installed(entry.id) {
                standing = .needsSetup(instructions[entry.id]
                    ?? .install("Install \(entry.name) to use it here"))
            } else if signedOut.contains(entry.id) || !credentialed(entry.id) {
                standing = .needsSetup(instructions[entry.id]
                    ?? .signIn("Sign in to \(entry.name)"))
            } else {
                standing = .ready
            }
            return Agent(id: entry.id, name: entry.name, glyph: entry.glyph,
                         standing: standing)
        }
    }

    /// **The only place a sign-out is ever discovered.**
    ///
    /// A turn came back saying the user is not authenticated. That is not a
    /// failure of this app and must not read as one: it is the agent asking
    /// for a login, and the answer is to say so and offer the step. Measured
    /// 14 Sep — a logged-out Devin completes the ACP handshake AND
    /// `session/new` and only fails at the prompt, so this is the first moment
    /// the truth is available at all.
    public static func signOut(in reason: String) -> Step? {
        let lowered = reason.lowercased()
        let says = ["log in", "login", "sign in", "signin", "not authenticated",
                    "unauthenticated", "unauthorized", "authentication required",
                    "auth required", "invalid api key", "expired token"]
        guard says.contains(where: { lowered.contains($0) }) else { return nil }
        // The vendor's own sentence, trimmed of the protocol noise around it.
        // Better than anything we would write: it names the command.
        return .signIn(reason.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
