import Foundation

/// A4 depth-1, Core half. DORMANT: nothing in the current announce flow calls
/// this — the app layer wires it to the ⌃⌃ double-tap (whose handler is a no-op
/// today) once the stage arbiter lands. `announceNext` is unchanged.
///
/// The ⌃⌃ pull goes one level deeper than the announcement: the rationale and
/// the risk, composed from the brief's card fields. The prompt already instructs
/// the model to write goal/risk/question "to stand alone" because they are
/// "also what the user hears if they ask for the rationale" — this is that path.
public enum SpokenComposition {
    /// ~10 seconds of speech at the measured rate. Depth-1 is a pull, not a
    /// page: the budget is a target, and the clamp drops whole sentences (in
    /// question, risk, goal reverse-priority order, since the clamp trims from
    /// the tail) rather than ever cutting mid-clause.
    /// Ruled 05 Aug: 40 hard. The prompt aims at ~30 (Haiku's verbosity floor
    /// for this content is ~50 regardless of the stated number — measured across
    /// three calibration rounds, see docs/prompt-rationale-spec.md), so THIS
    /// clamp is the enforcement, cutting at a sentence boundary. The sacrifice
    /// order is right by construction: the template puts "We propose X because
    /// Y" first and "careful about Z" second, so trailing state goes first.
    public static let depthOneMaxWords = 40

    /// The spoken depth-1 line for an announcement, callsign prefix applied
    /// exactly once via the same mechanical pass the announcement itself uses.
    /// Pure function over the announcement — no state, no speaking.
    public static func depthOneSpokenText(
        for announcement: Coordinator.Announcement,
        sanitizer: SpokenTextSanitizer = SpokenTextSanitizer(),
        allowing allowlist: Set<String> = []
    ) -> SanitizedSpokenText {
        depthOneSpokenText(
            brief: announcement.brief,
            callsign: announcement.hailText,
            strippingLabels: [announcement.event.projectLabel],
            sanitizer: sanitizer,
            allowing: allowlist)
    }

    /// Which rung of the ⌃⌃ ladder a pull is — carried alongside the text so
    /// the panel can NAME what is being spoken ("◀ FINDINGS"), not just say it.
    public enum RungKind: String, Sendable {
        case findings = "FINDINGS"
        case solution = "SOLUTION"
        case why = "WHY"
    }

    public struct LadderRung: Sendable {
        public let kind: RungKind
        public let spoken: SanitizedSpokenText
    }

    /// The ⌃⌃ ladder, in the ruled order of the stack: FINDINGS (what the work
    /// turned up), SOLUTION (the shape of what is proposed), then WHY (the
    /// rationale — which alone falls back to the card fields for pre-rationale
    /// rows). Empty rungs are skipped, never padded: a trivial turn's ladder is
    /// one rung. Every rung is sanitized, clamped at the same 40, and speaks
    /// without a callsign — the pull answers the agent that just spoke.
    /// Guaranteed non-empty: the why rung's fallback bottoms out at
    /// "No further rationale recorded."
    public static func ladderRungs(
        for announcement: Coordinator.Announcement,
        sanitizer: SpokenTextSanitizer = SpokenTextSanitizer(),
        allowing allowlist: Set<String> = []
    ) -> [LadderRung] {
        let labels = [announcement.event.projectLabel, announcement.hailText]
        func rung(_ text: String?) -> SanitizedSpokenText? {
            guard let text, !text.isEmpty else { return nil }
            let sanitized = sanitizer.sanitize(
                text, maxWords: depthOneMaxWords, allowing: allowlist)
            return sanitizer.strippingLeadingLabels(labels, from: sanitized)
        }
        var rungs: [LadderRung] = []
        if let findings = rung(announcement.brief.findings) {
            rungs.append(LadderRung(kind: .findings, spoken: findings))
        }
        if let solution = rung(announcement.brief.solution) {
            rungs.append(LadderRung(kind: .solution, spoken: solution))
        }
        rungs.append(LadderRung(kind: .why, spoken: depthOneSpokenText(
            for: announcement, sanitizer: sanitizer, allowing: allowlist)))
        return rungs
    }

    /// Composition order is goal, then risk, then question: the clamp keeps
    /// leading sentences, and the question was already spoken at announce time
    /// (it ends the proposal), so it is the first thing sacrificed here.
    static func depthOneSpokenText(
        brief: SessionBrief,
        callsign: String,
        strippingLabels labels: [String],
        sanitizer: SpokenTextSanitizer = SpokenTextSanitizer(),
        allowing allowlist: Set<String> = []
    ) -> SanitizedSpokenText {
        // The model-written briefing is the product: "We propose X because Y.
        // We need to be careful about Z." — written at announce time in the same
        // call as everything else, so the pull still costs zero calls.
        if let rationale = brief.rationale, !rationale.isEmpty {
            let sanitized = sanitizer.sanitize(
                rationale, maxWords: depthOneMaxWords, allowing: allowlist)
            // No callsign prefix on depth-1: the pull answers the agent that just
            // spoke, so naming it again is redundancy, not attribution (ruled
            // 05 Aug). Any echo the model wrote is still stripped.
            return sanitizer.strippingLeadingLabels(labels + [callsign], from: sanitized)
        }

        // Fallback for briefs generated before the rationale field existed: the
        // card fields spoken as plain clauses. No "The goal is" glue — template
        // scaffolding read aloud was the original complaint (user report,
        // 05 Aug); plain content beats labeled content in the ear.
        var parts: [String] = []
        if let goal = brief.goal, !goal.isEmpty { parts.append(sentence(goal)) }
        if let risk = brief.risk, !risk.isEmpty { parts.append(sentence(risk)) }
        if let question = brief.question, !question.isEmpty { parts.append(sentence(question)) }

        // Null-safe: a floor brief may carry none of the card fields. Say so
        // rather than going silent — a pull that answers with nothing at all
        // reads as the gesture being broken.
        let composed = parts.isEmpty
            ? "No further rationale recorded."
            : parts.joined(separator: " ")

        let sanitized = sanitizer.sanitize(
            composed, maxWords: depthOneMaxWords, allowing: allowlist)
        return sanitizer.strippingLeadingLabels(labels + [callsign], from: sanitized)
    }

    /// Card fields are clauses, not sentences. Terminal punctuation makes each
    /// one a sentence of its own, so the clamp can drop them independently.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, ".?!".contains(last) else { return trimmed + "." }
        return trimmed
    }
}
