# Phase 1b — tuned prompt port + callsign, digit grounding, tolerances, allowlist

`swift build` clean, `swift test` green: 91 tests (65 existing + 26 new), zero
existing tests adapted — none asserted the old prompt text or the old
genericizing behavior directly, so the new contract required only additions.
No git commit made. Builds on the uncommitted WS-C/StateLegend refactor,
untouched.

**App-layer boundary (mid-flight amendment)**: a parallel session owns
`Sources/TranquilityApp/` (main.swift, StatusHUD.swift, HotkeyMonitor.swift,
PanelState.swift, StateLegend.swift). ZERO hunks in those files — nothing was
edited there and nothing needed reverting. The entire strip-and-prepend
composition lives in Core: `Coordinator.summarize` mints/loads the callsign and
hands the app a fully-composed `Summary.spoken` (callsign prefix + recap +
proposal); the callsign itself is exposed via `WaitingSession.callsign` (and
therefore `Announcement.event.callsign`). The app layer speaks and displays
what Core hands it, unmodified.

## Files touched

- `Sources/TranquilityCore/Summarizer.swift` — tuned prompt ported;
  `correctiveNote` on `SummaryRequest`; chain gains empty-source skip, digit
  grounding with one retry, speakable-names allowlist, and a `trace` hook.
- `Sources/TranquilityCore/Callsign.swift` — **new**: directory word, topic
  word selection, deterministic minting with collision checks, prefix stripping.
- `Sources/TranquilityCore/DigitGrounding.swift` — **new**: source number
  pool (digits + spelled one..ninety-nine), ungrounded detection over
  recap/proposal, conservative clause scrubbing.
- `Sources/TranquilityCore/Sanitizer.swift` — `sanitize(_:maxWords:allowing:)`
  allowlist for the identifier rules only; `speakableTerms(in:)`;
  `applyingCallsign(_:strippingLabels:to:)` (lives here because only this file
  can mint a `SanitizedSpokenText`).
- `Sources/TranquilityCore/QueueStore.swift` — new migration
  `v4_session_callsign` (old migrations untouched); `callsign(for:)`,
  `mintCallsign(_:for:)` (first-write-wins), `activeCallsigns(excluding:)`;
  the four `WaitingSession` queries LEFT JOIN the callsign.
- `Sources/TranquilityCore/Models.swift` — `WaitingSession.callsign` exposed
  for future UI use.
- `Sources/TranquilityCore/Coordinator.swift` — `summarize` now mints/loads
  the callsign and applies the mechanical prefix; traces empty-source skips and
  digit scrubs with the event id.
- `Tests/TranquilityCoreTests/Phase1bTests.swift` — **new**, 26 tests.
- `docs/phase-1b-changes.md` — this file.

## 1. Prompt port

`AnthropicSummaryProvider.systemPrompt` is now the vnext-a prompt verbatim
(three replay rounds + 50-record generalization pass). The pre-tuning baseline
is preserved at `tools/replay/prompts/current.txt`, referenced from a comment at
the definition. Slot mapping:

- `{project_label}` appears in TWO places: the user-message context line
  ("Project: …", unchanged) and inside the recap rule itself. The latter forced
  `systemPrompt` to become `systemPrompt(projectLabel:)` — a static function
  rather than a constant — substituted exactly as the replay harness rendered
  it. `ModelCallLog` records the rendered form.
- `{notification_block}` `{branch_block}` `{opening_block}`
  `{last_assistant_message}` map one-to-one to the existing interpolations in
  `brief(for:)`; those were not changed.
- `parse()` untouched (first `{` to last `}`, fence-tolerant); JSON contract
  unchanged (recap/proposal/topic/goal/happened/nextStep/question/risk).

## 2. Mechanical callsign prefix

At `Coordinator.summarize` time (covers both `prepareNext` and `announceNext`,
including the re-prepare of an interrupted announcement):

1. Strip every leading label-like prefix from the spoken text — case-insensitive
   `<label>:` for the project label, the live session name (from the agents
   API), and the callsign itself — looping until none match, so
   `"promotions: promotions:"` collapses entirely.
2. Prepend `"<callsign>: "` exactly once.

Doubling is impossible by construction (the callsign is in its own strip list,
so re-application is idempotent — pinned by `testDoubledPrefixIsImpossible`).
Brand-substituted prefixes ("Kopi:" from a promotions session) are NOT stripped
— the spec enumerates exactly three strippable labels — but attribution is
still correct because the true callsign always speaks first
(`testBrandSubstitutedPrefixStillGetsCorrectAttribution`).

## 3. Callsign mint algorithm

Two words, `<directory-word> <topic-word>`, lowercase. Deterministic, no model
call. Minted once at the session's first successful summary, frozen in GRDB
(`session_callsign`, migration `v4_session_callsign`; `INSERT … ON CONFLICT DO
NOTHING`, so a racing second mint loses and reads back the stored value).

- **Directory word**: last path component of cwd; home directory → `"home"`;
  worktrees → the component after `worktrees/` (mirrors `StatusHUD.identify`,
  reimplemented in Core — the app module cannot be imported from Core).
- **Topic word**: from the brief's topic; skip stopwords (standard list + a few
  corpus fillers: "session", "work", "task", "update"), the directory word,
  bare numbers, and words under 3 letters. "Most distinctive" = longest word,
  ties broken by earlier position.
- **Collision checks** against OTHER active sessions' callsigns (active =
  minted sessions with an event in the last 48h, excluding self): reject
  case-insensitive equality of the full callsign OR Levenshtein ≤ 2 between
  topic words. On rejection take the next-most-distinctive word; if all
  candidates are rejected, append a distinguishing topic word
  (`"promotions copy edit"`); if nothing distinguishes, accept the
  near-collision rather than fail.
- Used for the spoken prefix and exposed as `WaitingSession.callsign`.

## 4. Digit grounding (open issue #9)

In `SummarizerChain.summarize`, between provider parse and sanitization:

- **Pool**: digit tokens (`\d+` with optional `.`/`,` separators, commas
  normalized away, sub-runs included so "3.14" also grounds "3") plus spelled
  numbers one..ninety-nine (hyphenated and spaced compounds), from the agent's
  final message + opening block + notification matcher + project label. The
  pool is deliberately generous: a false positive costs a clause.
- **Detection**: digit tokens in recap/proposal absent from the pool.
- **Policy**: retry the SAME provider once with `correctiveNote` ("Your
  previous reply spoke the number(s) X not present in the source. Remove or
  correct them.") appended to the user message. If the retry is clean it is
  used; if still ungrounded, the offending tokens' minimal clauses (split on
  `,;:` and sentence bounds) are scrubbed, with a literal-removal backstop so
  the number can never be spoken, and the provider is tagged
  `+digit-scrubbed`. The Coordinator logs the scrub with the event id.
  Never crashes; the deterministic floor copies from the source and is
  grounded by definition.
- If scrubbing empties the recap, the card fields the assembled fallback would
  speak (happened/nextStep/question) are scrubbed too — otherwise the fallback
  path would smuggle the number back in.

## 5. Tolerances

- **Empty proposal**: already handled by `SessionBrief.spokenText()` (recap
  alone, no trailing separator); now pinned by a test.
- **Empty source**: the chain checks before any provider runs. An
  empty/whitespace final message never reaches a model — the deterministic
  floor answers, tagged provider `"empty-source"`, traced with the event id by
  the Coordinator.

## 6. Sanitizer allowlist

`sanitize` accepts `allowing: Set<String>`; ONLY the identifier-genericizing
rules (`symbol` camelCase/snake_case, `opaque-token`) consult it — paths,
hashes, UUIDs, URLs, filenames, and markdown are stripped regardless.
`speakableTerms(in:)` builds the set from the SOURCE message: capitalized
simple words (one initial capital, no interior capitals — "Klaviyo" yes,
"BuildLockedAssets" no) plus a tiny static known-product list for
lowercase-start brands the camelCase rule used to eat ("iPhone", "macOS",
"iTerm2", …). When unsure, the stripping behavior wins. The chain passes the
allowlist to all three sanitize calls.

## Tests added (26, in Phase1bTests.swift)

Directory word (worktree/home/fallback ×3), minting (distinctiveness,
stopwords, exact + near collision, exhaustion-append, nil on wordless topic
×5), GRDB freeze + active-set scoping (×2), mechanical prefix (strip+prepend,
doubled-prefix impossibility, brand substitution, live-name strip ×4), digit
grounding (grounded passes, ungrounded caught, spelled "ten" grounds "10",
clause scrub, chain retry-with-note, persistent-scrub ×6), tolerances (empty
proposal, empty source never calls model ×2), allowlist (product token
speakable, identifiers still stripped, paths/hashes never speakable ×3),
end-to-end announcement prefix + freeze + WaitingSession exposure (×1).

## Judgment calls

1. **"Most distinctive word" heuristic**: longest word, ties by position. Any
   deterministic proxy was allowed; length correlates best with specificity in
   3-6 word topics and is trivially explainable.
2. **Mint skips failure providers**: "first successful summary" excludes
   `deterministic-fallback` / `empty-source` / `none`, so a transient API
   outage cannot freeze a floor-quality name forever. A configured
   deterministic-only chain (provider `"deterministic"`) still mints. When the
   topic offers no usable word (`mint` returns nil — typical of floor output
   where topic == label), nothing is frozen; the directory word alone is
   spoken as the prefix and minting retries at the next summary.
3. **Near-collision compared against the LAST word** of an existing callsign
   (its topic word), including three-word appended callsigns.
4. **"Active" for collision purposes** = other minted sessions with an event in
   the last 48h (store-derived), not the agents API — deterministic, testable,
   and unaffected by probe hiccups.
5. **Prefix stripping is limited to the three specified labels.** Considered
   stripping ANY leading `Word:` (which would also catch the "Kopi:" residue),
   rejected: a recap may legitimately open with e.g. "Warning:", and the spec
   enumerates exactly three matches. The residue sits behind a correct
   callsign, which the spec's construction guarantees is the attribution heard.
6. **Digit check covers digit tokens in the output only** (per spec); spelled
   numbers are normalized on the SOURCE side so "ten" grounds "10". The pool
   includes the project label ("m3-tracker" makes "3" speakable) — generous on
   purpose.
7. **Retry goes to the same provider** that produced the ungrounded brief, not
   down the chain — the correction is about that provider's output.
8. **The allowlist never affects structural rules.** It can only exempt a token
   from the camelCase/snake_case/opaque rules; nothing can make a path or hash
   speakable.
9. **`applyingCallsign` does not re-sanitize.** The text is already sanitized;
   re-running the rules could eat the callsign itself (a worktree word like
   "product-image-binding-oracle" is 24+ chars — opaque-token territory). It
   constructs the `SanitizedSpokenText` directly, preserving redactions, which
   is why it lives in Sanitizer.swift next to the fileprivate init.

## Spec contradictions found (reported, not improvised)

1. **`summaryFailed` is no longer a reachable state.** The spec's item 5b says
   "mark the event summaryFailed" — but the v3 migration dropped the events
   `status` column entirely (events are append-only facts; `EventStatus`
   survives only as an enum used by `supersedePending`'s legacy SQL, which
   references a column that no longer exists on new stores). The closest
   existing failure path, used here: the chain returns provider tag
   `"empty-source"` without calling a model, and the Coordinator traces it
   with the event id.
2. **`StatusHUD.identify` cannot be reused from Core** (it is in the app
   module, which depends on Core, not vice versa) — the spec anticipated this
   ("reuse or mirror"); mirrored in `Callsign.directoryWord`, including the
   worktree rule, plus the home→"home" mapping the HUD does not have.
3. **The tuned prompt's recap rule needs the label inside the SYSTEM prompt**
   (`"{project_label}:"` in the MUST-open rule), which the previous
   static-`let` shape could not express. Ported as
   `systemPrompt(projectLabel:)` — the only structural deviation from a
   verbatim constant, and the substitution is exactly what the replay harness
   did.
4. Minor: the git worktree of this repo shows only `tools/replay` modifications
   as uncommitted; the WS-C/StateLegend refactor described as "uncommitted"
   appears already present in the working tree files (StateLegend.swift etc.
   exist and build). Nothing was reverted either way.
