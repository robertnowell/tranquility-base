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

    /// The WHY rung: the model-written rationale, or nothing.
    ///
    /// Until 14 Sep this fell back to reciting goal, risk and question when
    /// the rationale was null. Written 5 Aug, before the rationale field and
    /// before GOAL was a rung of its own (19 Aug); by September it spoke the
    /// goal twice on thirty-eight percent of ladders. Ruled 14 Sep: no
    /// fallback. If there is no rationale there is no rationale, and the rung
    /// is skipped like every other empty rung. Padding a rung to avoid silence
    /// was a gate on a context problem, and the context is now the prompt's
    /// job.
    public static func whyRung(
        for announcement: Coordinator.Announcement,
        sanitizer: SpokenTextSanitizer = SpokenTextSanitizer(),
        allowing allowlist: Set<String> = []
    ) -> SanitizedSpokenText? {
        guard let rationale = announcement.brief.rationale, !rationale.isEmpty else { return nil }
        let sanitized = sanitizer.sanitize(rationale, allowing: allowlist)
        // No callsign or label prefix on a pull: the pull answers the agent
        // that just spoke (ruled 05 Aug). Any echo the model wrote is stripped.
        return sanitizer.strippingLeadingLabels(
            [announcement.event.projectLabel, announcement.hailText], from: sanitized)
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
    /// proposed), then WHY (the rationale, when the model wrote one). Empty
    /// rungs are skipped, never padded: a trivial turn's ladder is one rung. Every rung is sanitized, spoken in full — a pull is an
    /// explicit ask for depth, so no clamp applies — and speaks
    /// without a callsign — the pull answers the agent that just spoke.
    /// Guaranteed non-empty: MESSAGE is always the last rung.
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
        if let why = whyRung(for: announcement, sanitizer: sanitizer, allowing: allowlist) {
            rungs.append(LadderRung(kind: .why, spoken: why))
        }
        // Already sanitized at announce time — replayed verbatim, never
        // re-clamped, so the rotation's "message" is exactly what was said.
        rungs.append(LadderRung(kind: .message, spoken: announcement.spoken))
        return rungs
    }

}
