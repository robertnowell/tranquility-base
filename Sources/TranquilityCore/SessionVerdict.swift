import Foundation

/// One place decides what a session IS, and it says who told it.
///
/// ## Why this exists
///
/// Five user-visible bugs in three days (30 Aug to 01 Sep) were one bug wearing
/// five hats. A session's state is derived from three independent witnesses, and
/// each witness had an "absent" case that was written down as a confident claim
/// which then outranked real evidence:
///
///     the process status was absent   and was spelled  "idle"
///     the Stop hook never fired       and was spelled  "still busy"
///     a rollout line was unreadable   and was spelled  "idle"
///
/// The last one held a lamp blue for fourteen hours over a turn that had died the
/// night before. The first turned every working Codex row grey, twice, three days
/// apart, because the fix for one re-exposed the fabrication under the other.
///
/// The 01 Sep research (`~/Documents/deep-research/2026-09-01-heterogeneous-agent-state`)
/// found the formal name for it: **conflating local absence with global absence**.
/// A witness that says "no process found" is making a claim about the harness it
/// can see, not about the world. Ours were allowed to vote as though they spoke
/// for everything.
///
/// Kubernetes reached the same rule from the other side and wrote it down in one
/// line: *"The absence of a condition should be interpreted the same as
/// `Unknown`."* Nagios draws the sharper version, and it is the one this app
/// needed: an UNKNOWN means *the checker itself failed*, never *the target is
/// fine*. Promoting the first into the second is exactly what `?? "idle"` did.
///
/// ## What this is NOT
///
/// Not a state machine. The problem has no hierarchy, only a flat merge of
/// witnesses, and the retrofit-regret literature is consistent that statecharts
/// cost more than they return at this size. Not event-sourced: the projection IS
/// the lamp, and the read-model machinery starts paying somewhere around 2,000
/// events, three orders of magnitude above this. Not probabilistic: no source in
/// any tier supports confidence-weighted fusion for a UI status, and it would
/// trade away the explainability that makes a wrong lamp diagnosable at all.
///
/// It is an ordered rule table over three-valued testimony, which is the shape
/// the evidence actually has.

// MARK: - Testimony

/// What one witness has to say, in three values rather than two.
///
/// The distinction that matters is between the first two cases, and it is the
/// one this codebase did not have:
///
/// - `outOfScope`: this witness cannot see this kind of session AT ALL. Codex
///   has no `agents --json`, so the process registry is not silent about a Codex
///   session, it is blind to it. A blind witness may never vote.
/// - `silent`: in scope, looked, and has nothing to say. A registry that covers
///   this harness and did not find the session. A file with no readable line.
/// - `says`: in scope, looked, and observed something.
///
/// Collapsing `outOfScope` and `silent` into "nil" is survivable. Collapsing
/// either into a `says` is the bug.
public enum Testimony<Observation: Equatable & Sendable>: Equatable, Sendable {
    case outOfScope
    case silent
    case says(Observation)

    /// The observation, when there is one. Deliberately the ONLY accessor:
    /// there is no `?? default` on this type and there must never be one, or
    /// the distinction above is lost at the first call site that wants a
    /// convenient answer.
    public var observed: Observation? {
        guard case .says(let observation) = self else { return nil }
        return observation
    }

    /// Whether this witness contributed anything. Absence is not evidence.
    public var spoke: Bool { observed != nil }
}

// MARK: - What each witness can say

/// What a live process reports about itself.
///
/// `alive` is the case that did not exist and had to. A Codex session has a
/// verified pid and an ownership record, so the process witness is very much in
/// scope and present, and it still has NOTHING to say about busy-versus-idle,
/// because Codex publishes no such status. That is neither `outOfScope` (we can
/// see the process) nor `silent` (we found it) nor `idle` (a claim we cannot
/// support). It is `alive`, and `alive` never decides working-versus-quiet.
public enum ProcessSays: Equatable, Sendable {
    /// The registry says this process is working.
    case busy
    /// The registry says this process is not working. A real observation from a
    /// harness that genuinely reports one, and it still outranks the file, which
    /// is the 18 Aug ruling and is correct when the claim is real.
    case idle
    /// The process is holding for a human and said so. Outranks everything.
    case waiting(short: String, full: String)
    /// Present and running, with no opinion on what it is doing.
    case alive
}

/// Which witness decided, carried on the verdict so a wrong lamp can be traced
/// in the log instead of in a screenshot.
public enum WitnessKind: String, Equatable, Sendable {
    case process
    case file
    case restart
    /// The user switched this row on, or a reply is in flight. Facts about US,
    /// not observations of the session, and deliberately the lowest precedence.
    case user
    case delivery
    /// Nothing had anything to say.
    case none
}

// MARK: - The verdict

/// What a session is, as distinct from what colour it draws.
///
/// Green is absent on purpose: "you have something unread" is decided by the
/// band that owns stored turns, not by this merge, and inventing a case here
/// that nothing can produce would be its own small lie.
public enum SessionState: String, Equatable, Sendable {
    /// Moving. Something is happening without you.
    case working
    /// Stopped on something it cannot pass alone. The needs-you channel.
    case blocked
    /// Alive with nothing in flight.
    case quiet
}

public struct Verdict: Equatable, Sendable {
    public let state: SessionState
    /// Who decided. The point of carrying it is that the row's caption, the
    /// hover text and the log line all come from one place, so they cannot
    /// disagree the way a lamp and its caption did on 18 Aug.
    public let witness: WitnessKind
    /// The row's short clause, when there is one.
    public let because: String?
    /// The whole sentence, for the hover.
    public let detail: String?

    /// The colour this verdict draws. A pure mapping, kept beside the states
    /// it maps so a new state cannot be added without answering for its lamp.
    ///
    /// Green is not here: "you have something unread" belongs to the band that
    /// owns stored turns, not to this merge.
    public var lamp: Lamp {
        switch state {
        case .working: return .working
        case .blocked: return .fault
        case .quiet:   return .running
        }
    }

    public init(state: SessionState, witness: WitnessKind,
                because: String? = nil, detail: String? = nil) {
        self.state = state
        self.witness = witness
        self.because = because
        self.detail = detail
    }
}

// MARK: - The arbiter

public enum SessionVerdict {

    /// Resolve one session's state from every witness, in one ordered pass.
    ///
    /// The order below is the EXISTING precedence, written down rather than
    /// changed: this function was extracted from `GridAssembler.lampAndReason`
    /// and must agree with it on every input, which the differential test
    /// asserts across the whole cross-product. The behaviour is old. What is new
    /// is that every step names its witness, and that a witness which did not
    /// speak cannot be mistaken for one that did.
    ///
    /// - Parameters:
    ///   - process: what the live process says, or why it cannot say anything.
    ///   - file: what the session's own transcript or rollout says.
    ///   - resumed: this process is newer than the words in the file, so the two
    ///     are describing different processes (`AgentRestart`).
    ///   - pickedUp: the user switched this row on. A fact about the user.
    ///   - isInFlight: a reply is on its way. A fact about us.
    public static func resolve(
        process: Testimony<ProcessSays>,
        file: Testimony<SessionActivity>,
        resumed: Bool = false,
        pickedUp: Bool = false,
        isInFlight: Bool = false
    ) -> Verdict {
        // 1. The process says it is holding for a human. Above everything: this
        //    is a process watched from outside saying it cannot go on alone, and
        //    the one move that helps is to put you in the terminal.
        if case .says(.waiting(let short, let full)) = process {
            return Verdict(state: .blocked, witness: .process, because: short, detail: full)
        }

        // 2. Restarted mid-turn, and told us nothing since. The process says idle
        //    and is right; the file says working and is right; they are talking
        //    about different processes. Suppressed only by a process that is
        //    visibly busy, because then blue is simply the truth.
        if process.observed != .busy, resumed,
           let said = AgentRestart.reason(for: file.observed) {
            return Verdict(state: .blocked, witness: .restart,
                           because: said.short, detail: said.full)
        }

        // 3. The file, with the process allowed to correct it ONLY where it has
        //    actually made a claim. `saysIdle` and `saysBusy` are false for
        //    `alive`, `silent` and `outOfScope` alike, which is the entire fix:
        //    a witness that never reported cannot overrule one that did.
        let saysIdle = process.observed == .idle
        let saysBusy = process.observed == .busy

        let observed: Verdict = {
            switch file.observed {
            case .working:
                // The file says a turn is in flight. A process that genuinely
                // reports idle knows something the file has not caught up with.
                return saysIdle
                    ? Verdict(state: .quiet, witness: .process)
                    : Verdict(state: .working, witness: .file)

            case .blocked(let reason):
                // An error is a fact the file states outright, and no process
                // status contradicts it: a session sitting on a usage limit is
                // idle by every measure the API has.
                return Verdict(state: .blocked, witness: .file,
                               because: SessionActivity.blocked(reason: reason).shortReason,
                               detail: reason)

            case .stalled(let reason):
                // A stall is an INFERENCE from silence, and silence is exactly
                // what a running process can speak to.
                if saysIdle { return Verdict(state: .quiet, witness: .process) }
                if saysBusy { return Verdict(state: .working, witness: .process) }
                return Verdict(state: .blocked, witness: .file,
                               because: SessionActivity.stalled(reason: reason).shortReason,
                               detail: reason)

            case .idle, nil:
                // The mirror: the file has nothing to say, the process says it
                // is chewing. Blue rather than quiet.
                return saysBusy
                    ? Verdict(state: .working, witness: .process)
                    : Verdict(state: .quiet, witness: file.spoke ? .file : .none)
            }
        }()

        // 4 and 5 speak only for rows that had nothing of their own to say.
        // Every rule above is a fact about the agent, and none of them may be
        // overwritten by a fact about the user.
        guard observed.state == .quiet else { return observed }
        if isInFlight { return Verdict(state: .working, witness: .delivery) }
        guard pickedUp else { return observed }
        return Verdict(state: .blocked, witness: .user,
                       because: "standing by",
                       detail: "You switched this session on. It is alive with nothing "
                             + "in flight, waiting for what you tell it next.")
    }

    /// What the live process amounts to as testimony.
    ///
    /// The one place a `LiveSession` becomes a witness, so the rules about what
    /// counts as an observation live together instead of at each call site.
    ///
    /// `harness` is used only for the case that has no `LiveSession` at all: a
    /// harness that registers with a liveness service and did not find this
    /// session has genuinely looked (`silent`), while a harness with no such
    /// service never could (`outOfScope`). This is the first place
    /// `HarnessCapabilities.registersWithLiveness` is CONSULTED rather than
    /// merely recorded, which the 01 Sep research named as the gap between
    /// documenting the harness differences and enforcing them.
    public static func testimony(of live: LiveSession?, harness: String? = nil,
                                 resumed: Bool = false) -> Testimony<ProcessSays> {
        guard let live else {
            guard let harness,
                  !KnownHarnesses.adapter(for: harness).capabilities.registersWithLiveness
            else { return .silent }
            return .outOfScope
        }
        if let at = WaitingAt.read(status: live.status, waitingFor: live.waitingFor,
                                   resumed: resumed) {
            return .says(.waiting(short: at.short, full: at.full))
        }
        switch live.status {
        case "busy": return .says(.busy)
        case "idle": return .says(.idle)
        // Present, running, and with no opinion. NOT idle. This is the case
        // that `?? "idle"` used to swallow, and it is why a Codex agent that was
        // visibly mid-tool-call sat grey in the grid on 30 Aug and again on
        // 01 Sep.
        default: return .says(.alive)
        }
    }
}
