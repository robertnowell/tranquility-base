import Foundation

/// A4 depth-1, Core half. LIVE: the app layer wires `ladderRungs` to the ⌃⌃
/// double-tap (walk + rung prewarm in main.swift). The DORMANT note this
/// header carried outlived the wiring by weeks — corrected 20 Aug 2026.
/// `announceNext` is unchanged.
///
/// The ⌃⌃ pull goes one level deeper than the announcement: the rationale and
/// the risk, composed from the brief's card fields. The prompt already instructs
/// the model to write goal/risk/question "to stand alone" because they are
/// "also what the user hears if they ask for the rationale" — this is that path.
public enum SpokenComposition {

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
        /// The first rung (ruled 19 Aug): which piece of work this is.
        ///
        /// The callsign used to answer that and was removed deliberately, which
        /// left the ladder opening on FINDINGS — the details of a turn whose
        /// subject nobody had stated. Pulling ⌃⌃ on a session and hearing what
        /// the work turned up, without being told what the work IS, is the gap
        /// this closes.
        case goal = "GOAL"
        case findings = "FINDINGS"
        case solution = "SOLUTION"
        case why = "WHY"
        /// The original announcement, re-heard. RULED 05 Aug: the rung after
        /// WHY — the walk ends where it began, because the proposal you only
        /// half-followed the first time lands differently once findings,
        /// solution and rationale have each had their turn.
        case message = "MESSAGE"
    }

    public struct LadderRung: Sendable {
        public let kind: RungKind
        public let spoken: SanitizedSpokenText
    }

    /// The ⌃⌃ ladder, in the ruled order of the stack: GOAL (which work this
    /// is), FINDINGS (what the work turned up), SOLUTION (the shape of what is
    /// proposed), then WHY (the rationale — which alone falls back to the card
    /// fields for pre-rationale rows). Empty rungs are skipped, never padded: a trivial turn's ladder is
    /// one rung. Every rung is sanitized, spoken in full — a pull is an
    /// explicit ask for depth, so no clamp applies — and speaks
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
                text, allowing: allowlist)
            return sanitizer.strippingLeadingLabels(labels, from: sanitized)
        }
        var rungs: [LadderRung] = []
        // First, because "which session is this?" is the question you have
        // before any other, and nothing else on the ladder answers it since the
        // callsign left. Skipped when the brief carries no goal, like every
        // other rung — a ladder is never padded.
        if let goal = rung(announcement.brief.goal) {
            rungs.append(LadderRung(kind: .goal, spoken: goal))
        }
        if let findings = rung(announcement.brief.findings) {
            rungs.append(LadderRung(kind: .findings, spoken: findings))
        }
        if let solution = rung(announcement.brief.solution) {
            rungs.append(LadderRung(kind: .solution, spoken: solution))
        }
        rungs.append(LadderRung(kind: .why, spoken: depthOneSpokenText(
            for: announcement, sanitizer: sanitizer, allowing: allowlist)))
        // Already sanitized at announce time — replayed verbatim, never
        // re-clamped, so the rotation's "message" is exactly what was said.
        rungs.append(LadderRung(kind: .message, spoken: announcement.spoken))
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
                rationale, allowing: allowlist)
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
            composed, allowing: allowlist)
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
