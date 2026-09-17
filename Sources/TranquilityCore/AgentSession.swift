import CryptoKit
import Foundation

/// An agent somewhere else, as this app models it.
///
/// **The noun is agent.** One row per agent, wherever it runs and however it
/// is driven (ruled in #366). This type is the CLOUD half of that: an agent
/// supervised by polling or subscribing to one authority that cannot be raced.
/// The local half is `HarnessAdapter`, where an agent is supervised by owning a
/// process, hooks push events, keystrokes go out, and two witnesses are merged
/// because they disagree. Those are different control planes and they are
/// deliberately not unified here. **They meet at the event and at the row, not
/// at the interface.**
///
/// Named `AgentSession` rather than `Session`, and the reason is arithmetic:
/// Core already declares eighteen `Session*` types (`Session`, `SessionState`,
/// `SessionRow`, `SessionVerdict`, `SessionActivity`, `SessionDiscovery`, the
/// `SessionOwnership*` family, and on), every one meaning a local terminal
/// session owned by a process. Plain `Session*` would collide with all of them
/// and mean the opposite control plane. `Task*` would bake crobot's vocabulary
/// into the model, which is the failure this design exists to prevent: crobot
/// says task, OpenHands says conversation, Devin says session, Cursor says
/// agent-and-runs, OpenCode says session, Claude Code says session.
public struct AgentSession: Sendable, Equatable, Identifiable {

    /// Hex and dashes, 64 characters or fewer, always. See `AgentSession.id(_:)`.
    public typealias ID = String

    public var id: ID
    /// **What the PROVIDER calls this session**, before `AgentSession.id`
    /// reduced it to something addressable.
    ///
    /// Carried because that reduction is ONE-WAY: anything not already hex and
    /// dashes is hashed, so no caller can recover the vendor's own identifier
    /// from `id`, and every egress call needs it. Without this each provider
    /// would keep a private reverse map, which is four copies of one fact and
    /// four chances for it to go stale.
    ///
    /// Equal to `id` whenever the provider's identifier was already
    /// addressable, which is the common case: crobot's task ids are UUIDs.
    public var providerID: String
    /// `AgentProvider.id`. Carried on the value rather than re-derived at each
    /// use, for the reason `LiveSession.harness` documents at length: a value
    /// that knew its provider and dropped it makes every downstream caller
    /// guess, and they all guess the same wrong default.
    public var provider: String
    /// What the provider calls it. May be empty while the provider has not
    /// named it yet, which is not an error: `SessionRow.displayName` already
    /// knows how to fall back.
    public var title: String
    public var state: AgentSessionState
    /// When the PROVIDER last said something changed, not when we last asked.
    /// The distinction is the same one `LiveSession.startedAt` exists to draw.
    public var updatedAt: Date

    // MARK: - Optional, because some providers populate them and others cannot

    /// The repository this agent is working in, when it has one. crobot and
    /// every cloud vendor surveyed carry one; local OpenCode does not, which is
    /// exactly why it is built at the same time.
    public var repository: String?
    /// The pull request, when the provider produces one. Gated by
    /// `Capabilities.carriesPullRequest`, so a provider that never opens a PR
    /// is absent here rather than reporting an empty one.
    public var pullRequest: URL?
    /// Where a person looks at this agent in the provider's own interface.
    public var url: URL?
    /// The directory the agent works in on THIS Mac, when it has one. An ACP
    /// agent always does (it is the child's cwd); a cloud agent never does.
    /// The spool line carries it as the event's cwd, which is what a summary
    /// request and a git-branch lookup read.
    public var directory: String?
    /// The provider's own interface on THIS Mac, when it is a program rather
    /// than a page: OpenCode's TUI opens a session with `opencode --session`.
    /// Go to Agent for a row with no pane and no page (#470).
    public var shell: ShellDoor?

    public struct ShellDoor: Sendable, Equatable {
        public var command: String
        public var directory: String
        public init(command: String, directory: String) {
            self.command = command; self.directory = directory
        }
    }

    public init(id: ID, provider: String, title: String = "",
                state: AgentSessionState = .unknown, updatedAt: Date = Date(),
                repository: String? = nil, pullRequest: URL? = nil, url: URL? = nil,
                providerID: String? = nil) {
        self.id = id
        // Defaulting to `id` is right rather than lazy: they ARE the same
        // string for every provider whose identifiers are already addressable.
        self.providerID = providerID ?? id
        self.provider = provider
        self.title = title
        self.state = state
        self.updatedAt = updatedAt
        self.repository = repository
        self.pullRequest = pullRequest
        self.url = url
    }

    /// A provider's own identifier, reduced to something this app can address.
    ///
    /// **`ArtifactStore.isPlausibleSession` refuses anything that is not hex
    /// and dashes within 64 characters, and a refused id gets no hub page.**
    /// That is not a check to route around: the same predicate guards what gets
    /// written into the agents tree at all. So a provider id that already
    /// satisfies it is kept verbatim (crobot's task ids are UUIDs, and a
    /// recognisable id is worth a great deal when someone is reading a log),
    /// and anything else is hashed rather than mangled.
    ///
    /// Hashed, not truncated or stripped: two OpenCode session names differing
    /// only in a character the filter would remove must not collide, and a
    /// collision here silently merges two agents into one row.
    ///
    /// The provider is mixed into the hash so two providers cannot produce the
    /// same app-side id from the same raw string.
    /// A session built from the provider's own identifier, carrying both
    /// halves so nothing downstream has to reverse a hash.
    public static func of(_ raw: String, provider: String, title: String = "",
                          state: AgentSessionState = .unknown,
                          updatedAt: Date = Date()) -> AgentSession {
        AgentSession(id: id(raw, provider: provider), provider: provider, title: title,
                     state: state, updatedAt: updatedAt, providerID: raw)
    }

    public static func id(_ raw: String, provider: String) -> ID {
        if ArtifactStore.isPlausibleSession(raw) { return raw }
        let digest = SHA256.hash(data: Data("\(provider)\u{0}\(raw)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// What an agent is doing, in A2A's vocabulary verbatim.
///
/// Borrowed rather than invented, for three reasons: it is the most
/// thought-through of the candidates, it is the Linux Foundation one, and it
/// already covers every state observed across the six vendors surveyed,
/// including `authRequired`, which neither of the first two providers has but
/// which Jules-style plan approval resembles.
///
/// **An unrecognised value decodes to `.unknown` rather than throwing** (rule 1
/// of the provider seam: "the using side of an enumeration shouldn't fail on an
/// enumeration value it doesn't know"). A vendor adding a state must not be able
/// to empty the grid.
public enum AgentSessionState: String, Sendable, Equatable, CaseIterable, Codable {
    case submitted
    case working
    case inputRequired = "input-required"
    case authRequired = "auth-required"
    case failed
    case completed
    case canceled
    case rejected
    /// Also what a FAILED POLL yields. Never `.idle`, never `.completed`: not
    /// hearing from a provider is not evidence that its agents finished, and
    /// the conformance suite asserts this in both directions.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentSessionState(rawValue: raw) ?? .unknown
    }

    /// Whether this agent can still do anything. The finished states are the
    /// ones A2A groups as Finished.
    public var isFinished: Bool {
        switch self {
        case .failed, .completed, .canceled, .rejected: return true
        case .submitted, .working, .inputRequired, .authRequired, .unknown: return false
        }
    }

    /// Whether the agent has stopped and is waiting on a person. A2A groups
    /// these as Paused, and they are the only two states that may light amber
    /// on their own.
    public var isBlocked: Bool { self == .inputRequired || self == .authRequired }
}

// MARK: - Presentation

/// The five buckets, COMPUTED AND NEVER STORED.
///
/// Paseo's five presentation buckets are the right picture and the wrong
/// storage, and copying the storage would reintroduce a bug this codebase
/// already memorialises: a bucket enum has no ordinal, so writing one back
/// destroys the read-state model, which is two monotonic watermarks over an
/// append-only log ordered by row id. The specific damage is the act of
/// listening extinguishing a row with the answer still owed.
///
/// So this is a function of the state plus the cursors, evaluated for the lamp
/// and the card at the moment of drawing. There is deliberately nowhere to put
/// one.
public enum AgentPresentation: Sendable, Equatable {
    /// **Green. Your turn.** A question waiting on your judgment, something it
    /// said that you have not read, or a turn that finished and is standing by
    /// for the next one. All three are the same instruction to the user — say
    /// something — so they are one lamp.
    case yours
    /// **Blue. Its turn.** Chewing on the last thing you said.
    case working
    /// **Amber. Something unanticipated.** Auth expired, the provider refused,
    /// the run failed, nobody can reach it. Not a question: a thing that has to
    /// be repaired before the agent can go on at all.
    case problem

    /// Ruled 14 Sep 2026. An agent whose lamp is ON is green, blue or amber,
    /// and there is no fourth. The quiet lamp this enum used to carry (`idle`,
    /// "alive, nothing owed") is gone, because the grey circle means one thing
    /// only and it is not a state any agent can put itself into:
    ///
    /// > *"The only way to get to gray, or AKA idle, is if I turn off the lamp.
    /// > Any lamps turned on, that is to say agents that are in the grid, are
    /// > either green, blue, or amber. There's nothing else."*
    ///
    /// Which retired three separate mistakes in one go. A vendor's own word
    /// `idle` is GREEN, not quiet: crobot says `idle` when the sandbox is up
    /// and the turn is over, which is precisely "ready for the next turn".
    /// `unreachable` is AMBER, not quiet: a provider nobody can reach is an
    /// unanticipated thing needing attention, and rendering it calm was the
    /// captive-portal lie this bucket was split for on 13 Sep. And a pending
    /// question is GREEN, not amber: *"for something needs your judgment is
    /// great. That's like it needs you. It's your time to shine."*
    ///
    /// Read-state is deliberately NOT an input. It orders rows and it bolds
    /// them; it never colours one. Making unread a precondition for green is
    /// what kept every crobot task off the panel for a week.
    public static func bucket(state: AgentSessionState,
                              hasPendingRequest: Bool) -> AgentPresentation {
        // Amber first: a broken agent that also has something unread is broken.
        //
        // **A pending permission is AMBER** (revised 15 Sep, 7:47 PM). The
        // 14 Sep ruling made a question green, and it still is for a turn
        // that ends with one. A structured permission request is different:
        // the agent is BLOCKED on it, exactly as a local agent is blocked on
        // a dialog, and local dialogs have always been amber with the reason
        // in the column. Robert, on a remote agent that had waited 27 minutes
        // on a permission nobody had heard: "it seems hung, and the lamp is
        // not amber, and there is no decision or anything." Same colour for
        // the same situation, whichever side of the pipe the agent is on.
        if hasPendingRequest { return .problem }
        switch state {
        case .authRequired, .failed, .rejected, .unknown: return .problem
        case .submitted, .working: return .working
        case .inputRequired, .completed, .canceled: return .yours
        }
    }
}

// MARK: - What a provider can do

/// Declared per provider, never assumed uniform.
///
/// Forced by the survey rather than invented: Cursor returns 409 on a follow-up
/// to a running agent and Devin accepts one; Copilot has no message endpoint at
/// all; crobot's list has no creator filter while Cursor's is explicitly
/// caller-scoped. Warp's answer to the same problem is the right one, and it is
/// the rule here too: **surface the gap rather than hide it.**
///
/// Rule 5 of the provider seam applies to every field: a declared capability
/// nothing reads is worse than no capability, because it reads as a guarantee.
/// `CapabilityLivenessTests` fails when one goes dead.
///
/// Push-or-poll is deliberately NOT a field here. `AgentProvider.changes()`
/// returning nil *is* that declaration, which is a capability that cannot go
/// stale because production code has to branch on it to function at all.
public struct Capabilities: Sendable, Equatable {
    /// A new agent can be started from the panel.
    public var canStart: Bool
    /// A message can be sent to an existing agent.
    public var canSend: Bool
    /// A pending request can be answered structurally, rather than only by
    /// sending text and hoping.
    public var canAnswer: Bool
    public var canCancel: Bool
    /// Whether a send lands while the agent is `working`. False for Cursor,
    /// which answers 409; true for Devin.
    public var sendWhileWorking: Bool
    /// Whether `mine()` returns only this caller's agents. **False means the
    /// list is everybody's**, which is crobot: its list endpoint has no creator
    /// filter, so a row could otherwise appear for an agent this user cannot
    /// answer.
    public var listIsCallerScoped: Bool
    /// Whether this provider ever produces a pull request.
    public var carriesPullRequest: Bool

    public init(canStart: Bool = false, canSend: Bool = false, canAnswer: Bool = false,
                canCancel: Bool = false, sendWhileWorking: Bool = false,
                listIsCallerScoped: Bool = false, carriesPullRequest: Bool = false) {
        self.canStart = canStart
        self.canSend = canSend
        self.canAnswer = canAnswer
        self.canCancel = canCancel
        self.sendWhileWorking = sendWhileWorking
        self.listIsCallerScoped = listIsCallerScoped
        self.carriesPullRequest = carriesPullRequest
    }
}

// MARK: - The pieces that move

/// **Never a `Bool`.** Cursor returns 409 `agent_busy` while an agent is
/// working and Copilot has no follow-up endpoint at all, so a boolean cannot
/// carry the truth: "false" would mean refused, unsupported and failed at once,
/// and the panel would have nothing to say beyond "it did not work".
public enum SendOutcome: Sendable, Equatable {
    case accepted
    /// The provider looked at it and said not now. Retryable.
    case busy
    /// This provider has no way to do this at all. Not retryable, and the
    /// honest thing to tell somebody.
    case unsupported
    /// It failed, and this is why. A failure worth recording is recorded with
    /// its full reason (ruling, 11 Sep) -- app and provider words, never the
    /// user's own speech.
    case failed(reason: String)
}

/// An agent asking for something it cannot proceed without.
///
/// **Fetched separately from the state, never carried on it.** All six vendors
/// surveyed store them apart: Devin's status carries `blocked` while the
/// question lives in the messages array, crobot is identical in shape, and an
/// interface that couples them needs a rewrite on the first provider that
/// separates them, which is all of them.
///
/// **Carries MANY questions, not one** (corrected 13 Sep 2026, building #401).
/// The first draft modelled one prompt with one flat list of options, and that
/// cannot express what OpenCode actually sends: a request holds an array of
/// questions, each with its own options, its own multi-select flag and its own
/// free-text flag, and they are answered together as `answers: string[][]`.
///
/// That gap survived the two-stub negotiation in #367 because both stubs were
/// invented. Neither was modelled on a real vendor payload, so both agreed with
/// each other and with nothing else. The lesson is cheap here and expensive
/// after two providers are built on the wrong shape, which is the whole reason
/// this client is written before either of them.
///
/// A permission request is the degenerate case: one question, three options,
/// no custom text. It fits without a second type.
public struct PendingRequest: Sendable, Equatable, Identifiable {
    public var id: String
    public var session: AgentSession.ID
    /// One or more. Never empty.
    public var questions: [Question]

    public struct Question: Sendable, Equatable {
        /// What it wants, in the agent's own words.
        public var asked: String
        /// Empty means free text is the only answer.
        public var options: [Option]
        /// Whether more than one option may be chosen.
        public var allowsMultiple: Bool
        /// Whether an answer outside the options is accepted.
        public var allowsCustom: Bool

        public init(asked: String, options: [Option] = [],
                    allowsMultiple: Bool = false, allowsCustom: Bool = false) {
            self.asked = asked
            self.options = options
            self.allowsMultiple = allowsMultiple
            self.allowsCustom = allowsCustom
        }
    }

    public struct Option: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var kind: Kind

        /// ACP's permission vocabulary, which is the best off-the-shelf one
        /// found anywhere in the survey, plus `other` for an option that is not
        /// a permission decision at all (a plan choice, a branch name).
        /// `other` is what keeps this from being a permission-only model.
        ///
        /// OpenCode's permission reply values map exactly:
        /// `once` / `always` / `reject`.
        public enum Kind: String, Sendable, Equatable, Codable {
            case allowOnce = "allow_once"
            case allowAlways = "allow_always"
            case rejectOnce = "reject_once"
            case rejectAlways = "reject_always"
            case other
        }

        public init(id: String, label: String, kind: Kind = .other) {
            self.id = id; self.label = label; self.kind = kind
        }
    }

    public init(id: String, session: AgentSession.ID, questions: [Question]) {
        self.id = id; self.session = session; self.questions = questions
    }

    /// The single-question case, which is most of them and all permissions.
    public init(id: String, session: AgentSession.ID, asked: String,
                options: [Option] = []) {
        self.init(id: id, session: session,
                  questions: [Question(asked: asked, options: options)])
    }

    /// The first question's words, for a lamp caption or a spoken line that has
    /// room for one clause. Never the whole request: answering needs all of it.
    public var asked: String { questions.first?.asked ?? "" }

    /// A permission, as opposed to the agent's own question: every option
    /// is one of the allow/reject kinds.
    public var isPermission: Bool {
        guard let options = questions.first?.options, !options.isEmpty else { return false }
        return options.allSatisfy { $0.kind != .other }
    }

    /// The option the person meant, from what they said. An id or a label
    /// verbatim wins; otherwise the words are read for consent: "always"
    /// before "yes", because "yes, always" is an always. Nil when the words
    /// do not choose, so the caller can refuse rather than guess. The
    /// vocabulary is the ACP permission kinds this type was built from (#367).
    public func option(chosenBy words: String) -> Option? {
        let options = questions.first?.options ?? []
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = options.first(where: {
            $0.id.caseInsensitiveCompare(said) == .orderedSame
                || $0.label.caseInsensitiveCompare(said) == .orderedSame }) {
            return exact
        }
        let lower = said.lowercased()
        // A label said in part: "thorough" for "Thorough (Recommended)",
        // "standard" for "Standard". The agent's own questions carry labels
        // like these, and nobody says the parenthesis. One label whose first
        // word is in what was said wins; two is no choice.
        let byLabel = options.filter { option in
            let head = option.label.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? ""
            return head.count >= 3
                && lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: head))\\b",
                               options: .regularExpression) != nil
        }
        if byLabel.count == 1 { return byLabel[0] }
        if byLabel.count > 1 { return nil }
        func has(_ terms: [String]) -> Bool {
            terms.contains { term in
                lower.range(of: "\\b\(term)\\b", options: .regularExpression) != nil
            }
        }
        let kind: Option.Kind?
        if has(["always", "every time", "from now on", "don't ask again", "do not ask again"]) {
            kind = has(["no", "never", "reject", "deny", "don't", "do not"]) && !has(["yes", "allow", "ok", "okay", "go", "sure"]) ? .rejectAlways : .allowAlways
        } else if has(["never"]) {
            kind = .rejectAlways
        } else if has(["no", "reject", "deny", "don't", "do not", "stop", "cancel"]) {
            kind = .rejectOnce
        } else if has(["yes", "yeah", "yep", "allow", "ok", "okay", "go", "go ahead", "sure", "approve", "proceed", "do it", "fine"]) {
            kind = .allowOnce
        } else {
            kind = nil
        }
        guard let kind else { return nil }
        return options.first { $0.kind == kind }
            ?? (kind == .allowAlways ? options.first { $0.kind == .allowOnce } : nil)
            ?? (kind == .rejectAlways ? options.first { $0.kind == .rejectOnce } : nil)
    }
}

/// An answer to a `PendingRequest`.
///
/// **One entry per question, in order**, because that is how every provider
/// that asks more than one at a time accepts them back (OpenCode: `answers`,
/// an array of arrays). Each entry is the chosen option ids, or free text when
/// the question allows it.
public struct Response: Sendable, Equatable {
    public var answers: [[String]]

    public init(answers: [[String]]) { self.answers = answers }

    /// A single free-text or single-choice answer, which is the common case.
    public init(_ one: String) { self.answers = [[one]] }

    /// Reject the whole request. Distinct from answering "no" to its first
    /// question: a provider with a reject verb must be able to reach it.
    public static let rejected = Response(answers: [])
    public var isRejection: Bool { answers.isEmpty }
}

/// One thing said, by either side.
public struct Turn: Sendable, Equatable, Identifiable {
    public var id: String
    public var at: Date
    public var role: Role
    public var text: String

    public enum Role: String, Sendable, Equatable, Codable { case agent, user, system }

    public init(id: String, at: Date, role: Role, text: String) {
        self.id = id; self.at = at; self.role = role; self.text = text
    }
}

/// What to start an agent on.
public struct Brief: Sendable, Equatable {
    public var prompt: String
    /// Optional, because local OpenCode has no repository to name.
    public var repository: String?
    public var branch: String?

    public init(prompt: String, repository: String? = nil, branch: String? = nil) {
        self.prompt = prompt; self.repository = repository; self.branch = branch
    }
}

/// What a provider emits.
///
/// **Providers emit events. They do not answer status questions.** That is the
/// decision from #366 and the whole reason this type exists: an event lands in
/// the append-only log, which is what the read-state watermarks, the summariser
/// and the speech prewarm are all built over. A poller and a stream converge
/// here, which is the meeting point with the local control plane too: the
/// convergence is the event, not the interface.
public struct AgentEvent: Sendable, Equatable {
    public var provider: String
    public var session: AgentSession.ID
    public var at: Date
    public var kind: Kind
    /// What the poller knew this agent's state to be BEFORE this event, or
    /// nil when it knew nothing. Stamped by the poller on the way out, never
    /// by a provider: a provider reports what is, the poller is the one that
    /// remembers what was. It exists so a spool writer can tell a turn ENDING
    /// from any later change while the agent sits finished (a title arriving,
    /// a list re-read): the first is a turn, the second is not, and writing
    /// the second as a bare stop line put "finished a turn" over the words
    /// the agent had just said (15 Sep, Robert's first OpenCode turn).
    public var previously: AgentSessionState?

    public enum Kind: Sendable, Equatable {
        /// First sight of an agent, carrying everything known about it.
        case appeared(AgentSession)
        /// It moved. Carries the whole session rather than a delta, for the
        /// reason A2A's `tasks/resubscribe` returns a full snapshot: a client
        /// that missed a transition into a blocked state must not be able to
        /// stay wrong.
        case changed(AgentSession)
        case said(Turn)
        /// It cannot go on alone. The one event that lights amber.
        case asks(PendingRequest)
        /// A pending request was answered, possibly by somebody else, possibly
        /// in the provider's own interface. Without this an answered question
        /// holds an amber lamp for ever.
        case answered(requestId: String)
        /// Carries its reason (ruling, 11 Sep). App and provider words only.
        case failed(reason: String)
    }

    public init(provider: String, session: AgentSession.ID, at: Date = Date(), kind: Kind) {
        self.provider = provider; self.session = session; self.at = at; self.kind = kind
    }
}
