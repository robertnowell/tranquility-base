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
    public static let depthOneMaxWords = 25

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
        // Spoken labels, not written ones: "Goal:" read aloud is a bare word and
        // a click of silence — heard as a glitch, not a heading (user report,
        // 05 Aug). Full clauses survive text-to-speech.
        var parts: [String] = []
        if let goal = brief.goal, !goal.isEmpty { parts.append(sentence("The goal is " + goal)) }
        if let risk = brief.risk, !risk.isEmpty { parts.append(sentence("The risk is " + risk)) }
        if let question = brief.question, !question.isEmpty { parts.append(sentence(question)) }

        // Null-safe: a floor brief may carry none of the card fields. Say so
        // rather than going silent — a pull that answers with nothing at all
        // reads as the gesture being broken.
        let composed = parts.isEmpty
            ? "No further rationale recorded."
            : parts.joined(separator: " ")

        let sanitized = sanitizer.sanitize(
            composed, maxWords: depthOneMaxWords, allowing: allowlist)
        return sanitizer.applyingCallsign(callsign, strippingLabels: labels, to: sanitized)
    }

    /// Card fields are clauses, not sentences. Terminal punctuation makes each
    /// one a sentence of its own, so the clamp can drop them independently.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, ".?!".contains(last) else { return trimmed + "." }
        return trimmed
    }
}
