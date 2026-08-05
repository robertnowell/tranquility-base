# A7 lexicon + A2/A4 Core halves + WS-E counters groundwork

`swift build` clean, `swift test` green: 114 tests (91 existing + 23 new), zero
existing tests adapted. Core-only per the two-session contract: zero hunks in
`Sources/VoiceDispatchApp/` (the parallel session's uncommitted PanelState.swift
change was left untouched and uncommitted).

## Files touched

- `Sources/VoiceDispatchCore/Lexicon.swift` — **new**: the A7 shared lexicon.
- `Sources/VoiceDispatchCore/SpokenComposition.swift` — **new**: A4 depth-1
  composition (dormant).
- `Sources/VoiceDispatchCore/DogfoodCounters.swift` — **new**: WS-E event kinds,
  record API, computed counters.
- `Sources/VoiceDispatchCore/QueueStore.swift` — new migration
  `v5_dogfood_event` (appended; old migrations untouched).
- `Sources/VoiceDispatchCore/Transcription.swift` — `LiveTranscriptionProvider`
  gains `startSession(boosting:…)` with a forwarding default;
  `AppleSpeechRecovery` gains `lexicon` → `contextualStrings`.
- `Sources/VoiceDispatchCore/RecoveryChain.swift` — default init gains
  `lexicon:`, handed to the Apple floor.
- `Sources/VoiceDispatchCore/Summarizer.swift` — `summarize(_:lexicon:)`
  (defaulted; all existing call sites compile unchanged), unioned into the
  speakable-names allowlist.
- `Sources/VoiceDispatchCore/Coordinator.swift` — `Announcement.hailText`
  (dormant); `summarize` harvests the lexicon and passes it; the agents probe
  is hoisted so lexicon + prefix-stripping share ONE `agents.sessions()` call
  per summary (it was one before; naive wiring would have made it two).
- `Sources/vdctl/main.swift` — `vdctl dogfood [days]` and
  `vdctl dogfood record <kind> [note…]`.
- `Tests/VoiceDispatchCoreTests/LexiconTests.swift` (10),
  `SpokenCompositionTests.swift` (8), `DogfoodCountersTests.swift` (4+1) — new.

## Item 1 — A7: the shared lexicon

`Lexicon.harvest(store:liveSessionNames:)` builds one rolling vocabulary from
what is already in GRDB: recent events' `lastAssistantMessage` and
`summaryText` run through the Sanitizer's own `speakableTerms(in:)` (reused,
not duplicated — one definition of "speakable name"), plus seeds that bypass
the cap: every active callsign (via `activeCallsigns(excluding: "")` — the
empty id excludes nothing), every recent project label, and the live session
names the caller got from the agents probe. Window 48h (the same horizon that
defines an "active" callsign), recency-weighted (per-mention weight
`1 − age/window`, floored at 0.05, summed across mentions), deduped
case-insensitively with first-seen casing kept, capped at 100. Harvest never
throws — a degraded lexicon is not worth blocking an announcement for.

Three consumers:

1. **Live transcription** — there is NO AssemblyAI streaming implementation in
   the repo (see contradictions), so this is a protocol seam:
   `startSession(boosting:…)` on `LiveTranscriptionProvider`, with a default
   that forwards to the plain open for providers without vocabulary support.
   Vocabulary is fixed at session open, matching the spec's fallback ruling
   ("if the streaming handshake doesn't support mid-session updates, compute
   at session open").
2. **`AppleSpeechRecovery`** — `lexicon` property → `contextualStrings` on the
   recognition request; `RecoveryChain(lexicon:)` plumbs it through the
   default provider list.
3. **Sanitizer allowlist** — `Coordinator.summarize` harvests and passes
   `lexicon.allowlistTerms` into `SummarizerChain.summarize(_:lexicon:)`,
   which unions it with the per-message `speakableTerms`. Same constraint as
   the per-message set: it can only exempt tokens from the identifier rules —
   paths/hashes/UUIDs/filenames stay stripped regardless (pinned by test).

`allowlistTerms` additionally splits multi-word terms ("promotions copy" →
"promotions", "copy") because the sanitizer matches single tokens.

## Item 2 — A2/A4 Core halves (dormant, zero behavior change to announce)

- `Announcement.hailText` — just the callsign (directory-word fallback for an
  unminted session, mirroring `withCallsign`'s prefix rule). The chime is the
  app's job. Nothing in `announceNext` speaks it; comments say so.
- `SpokenComposition.depthOneSpokenText(for:)` — pure function over an
  `Announcement`: composes "Goal: …. Risk: …. <question>" from the brief's
  card fields (the prompt already makes the model write those "to stand
  alone"), sanitized at 25 words through the existing pipeline, callsign
  applied via `applyingCallsign` (exactly once by construction), null-safe
  fallback "No further rationale recorded."

`announceNext`'s returns and speech are untouched — verified by the 91
existing tests passing unmodified, including the Phase 1b end-to-end.

## Item 3 — WS-E counters groundwork

- Migration `v5_dogfood_event`: append-only `dogfood_event` (id, atMs, kind,
  sessionId?, note?), indexed on `atMs`.
- `DogfoodEventKind`: announcementSpoken, announcementActedOn,
  replayRequested, depthOnePulled, terminalDropBack, attributionError —
  snake_case raw values matching the store's existing enum style.
- `recordDogfood(_:sessionId:note:at:)` (at injectable for tests),
  `dogfoodCounts(since:)`, `dogfoodSummary(days:)`. Counters are computed by
  query, never stored. `actionability` = actedOn/spoken, **nil** when nothing
  was spoken (0/0 is "no data", not 0%).
- `vdctl dogfood [days]` prints the per-kind table + actionability.

## Judgment calls

1. **Consumer 1 is a protocol seam, not an edit to request-building code** —
   none exists (below). The `boosting` overload with a forwarding default was
   chosen over a mutable provider property so the vocabulary is visibly bound
   to session open, where the handshake actually sends it.
2. **`activeCallsigns(excluding: "")`** reuses the existing query rather than
   adding a near-duplicate; the empty session id matches no row, and unlike
   mint-time collision checks the lexicon wants the current session's own name.
3. **Allowlist matching stays exact-case** (the sanitizer's existing
   contract). This is sufficient: the identifier rules only fire on
   camelCase/snake_case/opaque tokens, which appear in output exactly as
   written; capitalized simple words never needed exemption in the first place.
4. **Harvest runs per `Coordinator.summarize`** (a few SQLite reads, no
   subprocess). The agents probe was hoisted so lexicon + callsign share the
   one `agents.sessions()` call summarize already paid — the private
   `withCallsign` signature changed to take it.
5. **Depth-1 order is goal, risk, question** — the clamp drops whole sentences
   from the tail, and the question was already spoken at announce time (it
   ends the proposal), so it is the first sacrifice. Worst-case prompt-lawful
   fields (12+12 words) can push the risk out; at measured field lengths
   (~8 words) all three fit in 25.
6. **The depth-1 word budget bounds the composed body**; the 2-word callsign
   prefix rides on top — same accounting as the main announcement, where the
   mechanical prefix is applied after clamping.
7. **`atMs` not `at`** for the column, matching every other timestamp column
   in the schema (`createdAtMs`, `heardAtMs`, …).
8. **`vdctl dogfood record` was added beyond the spec's summary table** — the
   item itself says attributionError is "manual/voice-reported"; until the
   voice path exists, the manual path IS vdctl. Counters that cannot be fed
   are not "live from the first WS-A build".
9. **Cap = 100 exactly**: AssemblyAI's v3 streaming keyterms limit is 100;
   realtime `word_boost` allows more, but one list that is valid for every
   consumer beats per-consumer truncation rules.

## Spec contradictions found (reported, not improvised)

1. **There is no AssemblyAI streaming implementation to wire.** The spec says
   "find where the realtime session is configured (Transcription.swift / the
   LiveTranscriptionProvider impl) and … match its style" — the repo contains
   the protocol only; no conformer exists in Core, App, or tests, and the only
   AssemblyAI artifacts are the Secrets key and a vdctl usage string. "Check
   what the streaming code sends today" therefore has the answer "nothing".
   Implemented as the ready-to-wire protocol seam above; the future impl
   overrides `startSession(boosting:…)` and puts the list in `word_boost`.
2. **"Briefs' topics/goals … already in GRDB" — briefs are not in GRDB.**
   Summaries live in the Coordinator's in-memory `PreparedSummaries`; events
   are append-only and their v1 `summaryText` column is never written by the
   current pipeline (it is carried through the queries for legacy rows).
   Harvest reads what IS durable — final messages, `summaryText` when a legacy
   row has one, labels, callsigns — which covers the same names the topics
   and goals would have contributed (they are distilled from those messages).
3. Minor: the working tree contained the other session's uncommitted
   `PanelState.swift` modification throughout; untouched, unread, uncommitted.
