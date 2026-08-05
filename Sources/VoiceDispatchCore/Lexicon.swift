import Foundation

/// A7: ONE rolling vocabulary of proper nouns and non-dictionary words, harvested
/// from recent session content, shared by three consumers:
///
/// 1. **Live transcription** — handed to the streaming provider at session open
///    (AssemblyAI realtime calls this `word_boost`; the v3 streaming API caps its
///    equivalent near 100 terms, which is where `maxTerms` comes from). Streaming
///    handshakes take their vocabulary once, so callers compute the lexicon
///    immediately before opening a session rather than trying to update mid-stream.
/// 2. **`AppleSpeechRecovery`** — applied as `contextualStrings` on the
///    recognition request, so the on-device floor biases toward the same names.
/// 3. **The sanitizer allowlist** — unioned into `allowing:` at announce time,
///    so a name recent sessions established stays speakable even when the one
///    message being spoken did not capitalize it.
///
/// The window is the last ~48h of events — the same horizon that defines an
/// "active" callsign — recency-weighted so a name from an hour ago outranks one
/// from yesterday, deduped case-insensitively, and capped. Active callsigns and
/// project labels are ALWAYS seeded, cap regardless: those are the words the user
/// says back at the app, and mishearing them breaks routing, not just spelling.
public struct Lexicon: Sendable, Equatable {
    /// Highest priority first: the seeds (callsigns, project labels, live session
    /// names), then harvested terms by recency-weighted score. Providers that
    /// truncate truncate from the tail, which drops the least valuable terms.
    public let terms: [String]

    /// AssemblyAI's v3 streaming keyterms limit is 100; realtime `word_boost`
    /// allows more, but the smaller bound keeps one list valid for every consumer.
    public static let maxTerms = 100
    /// Matches the callsign "active" horizon in `QueueStore.activeCallsigns`.
    public static let window: TimeInterval = 48 * 3600

    public init(terms: [String]) {
        self.terms = terms
    }

    /// The set consumed by `sanitize(_:maxWords:allowing:)`. Includes each term
    /// verbatim plus the individual words of multi-word terms — the sanitizer
    /// matches single tokens, so "promotions copy" can never match but
    /// "promotions" and "copy" can. Matching is exact-case, which is enough:
    /// the identifier rules only ever fire on camelCase/snake_case/opaque
    /// tokens, and those appear in output exactly as the source wrote them.
    public var allowlistTerms: Set<String> {
        var out = Set(terms)
        for term in terms where term.contains(" ") {
            out.formUnion(term.split(separator: " ").map(String.init))
        }
        return out
    }

    // MARK: - Harvest

    /// Build the lexicon from what is already in GRDB, never failing: a harvest
    /// hiccup degrades transcription bias, and degrading is not worth blocking
    /// an announcement for. `liveSessionNames` come from the agents probe, which
    /// only the caller has an answer for (and may not — nil probe means none).
    public static func harvest(
        store: QueueStore,
        liveSessionNames: [String] = [],
        now: Date = Date(),
        window: TimeInterval = Lexicon.window,
        cap: Int = Lexicon.maxTerms
    ) -> Lexicon {
        let cutoffMs = Int64((now.timeIntervalSince1970 - window) * 1000)
        let events = ((try? store.events(limit: 400)) ?? [])
            .filter { $0.createdAtMs >= cutoffMs }

        // Seeds bypass the cap. Deduped case-insensitively, first casing wins.
        var seen = Set<String>()
        var seeds: [String] = []
        func seed(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            seeds.append(trimmed)
        }
        // Every active session's callsign — excluding nothing (the empty session
        // id matches no row), because unlike mint-time collision checks the
        // lexicon wants the current session's own name too.
        for callsign in (try? store.activeCallsigns(excluding: "", activeWithin: window)) ?? [] {
            seed(callsign)
        }
        for event in events { seed(event.projectLabel) }
        for name in liveSessionNames { seed(name) }

        // Harvested terms: the Sanitizer's own extraction over recent final
        // messages (reused, not duplicated — one definition of "speakable name"),
        // weighted by the recency of each mention and summed across mentions.
        var score: [String: Double] = [:]
        var casing: [String: String] = [:]
        for event in events {
            let ageSeconds = now.timeIntervalSince1970 - Double(event.createdAtMs) / 1000
            let weight = max(0.05, 1.0 - ageSeconds / window)
            for source in [event.lastAssistantMessage, event.summaryText].compactMap({ $0 }) {
                for term in SpokenTextSanitizer.speakableTerms(in: source) {
                    let key = term.lowercased()
                    guard !seen.contains(key) else { continue }
                    score[key, default: 0] += weight
                    if casing[key] == nil { casing[key] = term }
                }
            }
        }

        var terms = seeds
        let ranked = score
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for entry in ranked {
            guard terms.count < cap else { break }
            if let cased = casing[entry.key] { terms.append(cased) }
        }
        return Lexicon(terms: terms)
    }
}
