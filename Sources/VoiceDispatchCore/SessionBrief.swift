import Foundation

/// What you need to know about one finished turn when ten sessions are in flight.
///
/// Prose alone doesn't work here. "The fix has never run in the deployed pipeline"
/// is true, but out of context it names no subject, proposes no action, and asks
/// nothing — you cannot act on it without opening the tab, which defeats the point.
/// So the model fills fields, and the spoken line is assembled from them in priority
/// order rather than being freely written.
public struct SessionBrief: Codable, Sendable, Equatable {
    /// Spoken section one: where things stand. Under 40 words.
    ///
    /// Uses Claude Code's own session-recap instruction verbatim — goal, current
    /// task, next action, and an explicit skip-list.
    public var recap: String?
    /// Spoken section two: what happens next and what it costs you to agree. Under
    /// 30 words.
    ///
    /// Separate from the recap because they serve different purposes: one orients,
    /// the other asks. It must carry the risk, not just the proposal — the failure
    /// mode being designed against is approving something you later regret, and a
    /// proposal without its risk is exactly how that happens.
    public var proposal: String?
    /// 3–6 words naming the subject. Always spoken first, because "which session?"
    /// is the question you have before any other.
    public var topic: String
    /// What this session set out to do. Comes from the opening ask, not the last turn.
    public var goal: String?
    /// What just concluded.
    public var happened: String
    /// The proposed next action, if there is a real one.
    public var nextStep: String?
    /// A genuine question being put to you. Blocks progress, so it outranks nextStep.
    public var question: String?
    /// A risk or uncertainty worth knowing before you answer.
    public var risk: String?

    // Deterministic — never written by the model.
    public var branch: String?

    // There is no `pullRequest` field, and that is deliberate.
    //
    // Looking one up from the branch announced "pull request 2023 is merged" for a
    // PR merged months earlier whose branch was still checked out — true, unrelated
    // to the work, and indistinguishable from a hallucination. The fix is not a
    // better query. It is noticing that the session already tells us: across every
    // session here that ran `gh pr create`, the assistant's own next message named
    // the PR correctly, 7 for 7. That text is already the summarizer's input.
    //
    // So a PR is spoken exactly when the session spoke about it. That is
    // attributable by construction, needs no `gh`, no GitHub, no worktree
    // convention, and no state — and it works the same for Codex or anything else
    // that ends a turn with a sentence about what it just did.

    public init(
        topic: String, goal: String? = nil, happened: String, nextStep: String? = nil,
        question: String? = nil, risk: String? = nil, branch: String? = nil,
        recap: String? = nil, proposal: String? = nil
    ) {
        self.recap = recap
        self.proposal = proposal
        self.topic = topic
        self.goal = goal
        self.happened = happened
        self.nextStep = nextStep
        self.question = question
        self.risk = risk
        self.branch = branch
    }

    /// The ~12 seconds you actually hear. Topic first so you know which session is
    /// talking, then the outcome, then the one thing that wants a decision. A
    /// question outranks a next step because it blocks; everything else is readable
    /// on the card.
    public func spokenText() -> String {
        // Prefer the authored sections. The assembled form is a fallback for the
        // deterministic provider, which has no model to write one.
        if let recap, !recap.isEmpty {
            var out = recap
            if let proposal, !proposal.isEmpty { out += " " + proposal }
            return out
        }
        var parts: [String] = ["\(topic)."]
        parts.append(happened.hasSuffix(".") ? happened : happened + ".")

        if let question, !question.isEmpty {
            parts.append(question)
        } else if let nextStep, !nextStep.isEmpty {
            parts.append(nextStep.hasSuffix(".") ? nextStep : nextStep + ".")
        }

        return parts.joined(separator: " ")
    }

    /// Everything, for the card in the queue and the overlay.
    public func cardLines() -> [(String, String)] {
        var lines: [(String, String)] = [("topic", topic)]
        if let goal { lines.append(("goal", goal)) }
        lines.append(("happened", happened))
        if let question { lines.append(("question", question)) }
        if let nextStep { lines.append(("next", nextStep)) }
        if let risk { lines.append(("risk", risk)) }
        // Branch is card metadata only — nobody needs a branch name read aloud.
        if let branch { lines.append(("branch", branch)) }
        return lines
    }
}


extension String {
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
