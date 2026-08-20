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
    /// 40 words (raised from 30 — see `SpokenTextSanitizer.proposalWords`).
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
    /// The ⌃⌃ briefing, model-written: "We propose X because Y. We need to be
    /// careful about Z." Spoken only on request, and spoken in full — the pull
    /// is an explicit ask for depth, so no clamp applies (measured 20 Aug: the
    /// model writes ~62 words median against the prompt's 40-word target, and
    /// dropping the tail severed the thought). Nil on briefs generated before
    /// the field existed — the composition falls back to the card fields.
    public var rationale: String?
    /// The ⌃⌃ ladder's first rung (ruled 05 Aug: findings → solution → why):
    /// what the work TURNED UP — results, numbers, surprises. Nil when the turn
    /// genuinely produced none; the rung is skipped, never padded.
    public var findings: String?
    /// The ladder's second rung: the concrete shape of the proposed work — the
    /// pieces, their order, "seven ranked; the top three…". Nil when nothing is
    /// proposed.
    public var solution: String?

    /// The hub page's header, model-written (A/B'd 11 Aug, "Should the
    /// summariser write the hub's headline?"; shipped 15 Aug when four days of
    /// derived headers answered the page's own "wait and look" verdict). The
    /// headline names the FINDING, not the topic; the deck says where things
    /// stand and what is left. Read, never spoken. Nil means the derived
    /// header renders exactly as before — the floor never moves.
    public var headline: String?
    public var deck: String?

    // Deterministic — never written by the model.
    public var branch: String?

    // There is no pull request field here, and the reason is no longer the
    // one this comment used to give.
    //
    // Two mechanisms tried to put one here on 18 Aug. The first asked the
    // summariser to copy a URL the turn printed: it filled 2 briefs in 1,299,
    // because assistants write "PR #117" and paste the URL once. The second
    // read "PR #117" with a regex and took the repository from the working
    // directory: it filed a pull request every time a turn MENTIONED one, and
    // it assembled a link to a pull request that had never existed.
    //
    // A pull request is not a property of a TURN'S TEXT. It is a property of a
    // BRANCH, GitHub knows it, and `branch` below is already deterministic. So
    // the hub asks. See `GitHubPullRequests`.

    public init(
        topic: String, goal: String? = nil, happened: String, nextStep: String? = nil,
        question: String? = nil, risk: String? = nil, rationale: String? = nil,
        findings: String? = nil, solution: String? = nil,
        branch: String? = nil, recap: String? = nil, proposal: String? = nil,
        headline: String? = nil, deck: String? = nil
    ) {
        self.recap = recap
        self.proposal = proposal
        self.topic = topic
        self.goal = goal
        self.happened = happened
        self.nextStep = nextStep
        self.question = question
        self.risk = risk
        self.headline = headline
        self.deck = deck
        self.rationale = rationale
        self.findings = findings
        self.solution = solution
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
