# STT and store: Whisper lexicon prompt, durable briefs, AssemblyAI streaming

Three work items, Core-only per the two-session contract (zero hunks in
`Sources/TranquilityApp/`). `swift build` clean, `swift test` green:
141 tests (114 existing + 27 new), zero existing tests adapted.

## Item 1 — the lexicon reaches Whisper (the primary ear)

`OpenAIRecovery` is the transcription path that actually runs today, and it was
the one A7 consumer the lexicon never reached. It now gains a `lexicon`
property mirroring `AppleSpeechRecovery`'s, plumbed through
`RecoveryChain(lexicon:)` to both default providers.

- The prompt is a natural-ish comma-joined list:
  `"The recording may mention: promotions copy, Klaviyo, …"` — sent as the
  transcription API's `prompt` field, which biases vocabulary and spelling.
- **Cap**: Whisper reads only the FINAL ~224 tokens of a prompt, so overflow
  silently drops the front — the worst place, where the seeds sit. The budget
  is therefore enforced client-side (180 estimated tokens, ~3 bytes/token
  conservative overestimate) and never delegated to the model.
- **Priority**: `Lexicon.terms` is already ordered seeds-first (callsigns,
  project labels, live session names — the words the user says back at the
  app), then harvested terms by recency-weighted score. The composer truncates
  from the tail, so callsigns and labels always survive.

Tests: composition/order, empty-lexicon → no prompt field, token cap,
seeds-survive-truncation, chain plumbing. (5 in LexiconTests.)

## Item 2 — briefs become durable (migration `v6_briefs`)

Briefs lived only in the in-memory `PreparedSummaries`; a restart lost every
card field (depth-1 amnesia), and the v1 `events.summaryText` column was never
written by the current pipeline.

- **Schema**: `brief` table, one row per event, keyed on the events rowid —
  the same "a brief is a brief OF one event" identity `PreparedSummaries`
  enforces (its `(sessionId, latestId)` check), with last-write-wins on
  re-prepare. Columns: `eventRowid, sessionId, atMs, topic, goal, happened,
  nextStep, question, risk, recap, proposal, callsign, provider`.
- **This table is deliberately the seed schema of the product's retention
  layer (the argument IR)**: topic/goal/happened/nextStep/question/risk are
  the argument's fields, recap/proposal its spoken projection,
  callsign/provider/atMs its provenance. Future retention features read this
  table; new columns should be named in those terms.
- **Write**: `Coordinator.summarize` persists after the callsign pass, under
  the same "successful summary" rule as callsign minting — the failure floors
  (`deterministic-fallback`, `empty-source`, `none`) are not remembered, so a
  transient outage's floor output is regenerated fresh after restart rather
  than replayed. Best-effort: a failed write degrades restart catch-up, never
  an announcement.
- **Read-through**: on a prepared miss (`announceNext` and `prepareNext`),
  the stored brief for that exact event is rebuilt into a `Summary` — same
  sanitizer, same mechanical callsign pass, same allowlist recipe (per-message
  speakable terms ∪ harvested lexicon, so a lexicon-vouched name is not
  re-redacted on restore) — with **zero model calls**, tagged
  `<provider>+stored`. A genuine store miss summarizes exactly as before;
  announce flow semantics are otherwise unchanged (nothing written before
  audio, cursor advance rules untouched — the 114 prior tests pass unmodified).
- **Harvest upgrade**: `Lexicon.harvest` now also credits stored topics
  (verbatim — a topic is the distilled name of the work) and goal proper nouns,
  recency-weighted like any other mention, not cap-bypassing seeds.

Tests: write-on-generate, failure-floors-not-persisted, read-after-restart
(fresh `QueueStore` on the same file), announce-after-restart with zero model
calls, depth-1 from the stored brief, harvest-includes-topics. (6 in
BriefStoreTests.)

Judgment calls:
1. `branch` is not persisted — deterministic card metadata, re-derivable from
   the transcript; not part of the argument.
2. `events.summaryText` stays unwritten — events are append-only facts by the
   v3 design; the brief table is the durable home, not a resurrected column.
3. Replay ("read me this session's last summary") also benefits: an explicit
   re-announce of an already-briefed event now reuses the stored brief instead
   of paying for a fresh model call.

## Item 3 — AssemblyAI Universal-Streaming, the first live provider

`AssemblyAIStreaming` (new, Core) is the first `LiveTranscriptionProvider`
conformer, over the v3 websocket (`wss://streaming.assemblyai.com/v3/ws`,
verified against the published API reference Aug 2026: raw-key `Authorization`
header, `sample_rate`/`format_turns` query params, binary PCM16 chunks
50–1000ms, `ForceEndpoint`/`Terminate` client messages, `Begin`/`Turn`/
`Termination` server messages).

- **Lexicon**: the `startSession(boosting:)` seam from 09cb796 lands in
  `keyterms_prompt` — a JSON-array query parameter, ≤100 terms, ≤50 chars each
  (`AssemblyAIStreaming.keyterms(from:)` enforces both, priority order
  preserved), fixed at session open.
- **State machine** (`AssemblyAITurnReducer`, pure and fake-socket-tested):
  partials accumulate across `Turn` messages; `end_of_turn` finalizes a turn
  (a formatted re-send overwrites its unformatted pass, keyed by
  `turn_order`); `Termination` with every turn finalized → `final` with
  `TranscriptFinality.explicitEndOfTurn`. Any unfinalized tail at close →
  `truncatedNoFinality` — a plausible-but-incomplete transcript must never
  pass as final. Socket death → `connectionDropped(hadPartialTranscript:)`.
- **RELIABILITY INVARIANT** (non-negotiable, and now pinned by tests): the
  audio file is written first, exactly as before, in
  `captureAndTranscribe(streamed:)`; a streamed result is accepted ONLY with
  an explicit end-of-turn, and everything else — nil, truncation, timeout,
  missing key — falls through to the existing file-based `RecoveryChain`
  unchanged. `StreamedUtterance` encodes the same contract for the app:
  `feed` never blocks or throws (pre-open chunks are buffered so a slow
  handshake cannot produce a plausible-but-incomplete final), `finish(timeout:
  3s)` returns nil on any doubt. Streaming adds speed; it cannot subtract
  reliability.
- **Provider tags**: `assemblyai-streaming` vs `openai`/`apple-speech`
  distinguish streamed from recovered transcripts in `utterances`.
- **App wiring**: capture lives in the App target (off-limits this session);
  the ≤5-line tap wiring is documented in `docs/log/wiring-streaming.md`.
  `Coordinator.submitReply` gained a defaulted `streamed:` parameter as the
  Core-side integration point — nil (the only value passed today) is
  byte-identical to the previous behavior.

### E2E result (`tbase transcribe-stream`, real key, real recording)

Run against `audio/93685E53….wav` (49.9s of real dictation, Aug 2) with the
real AssemblyAI key (recovered from the claude-secrets broker into the app's
secrets file via `tbase set-key assemblyai --from-env` — it was NOT already in
the app's Secrets, see contradictions):

- 100 keyterms sent from the live harvested lexicon.
- Partials streamed continuously while chunks were paced at ~realtime
  (100ms chunks / 90ms sleeps).
- Final: `[assemblyai-streaming, explicit_end_of_turn, final 1079ms after
  end-of-audio]` — a clean, formatted, accurate transcript of the whole
  recording ("…the Whisper flow where it doesn't show time passing… max 10
  bars or something like that…").
- The no-key path was also exercised (before the key was stored): the command
  reports `assemblyai key is not configured — run: tbase set-key assemblyai`
  and exits 2 rather than failing silently.

Tests: partial accumulation, explicit final, formatted-turn overwrite,
multi-turn join, truncation (two shapes), no-speech, socket error, handshake
frames (`ForceEndpoint` then `Terminate`), keyterms cap + query encoding +
auth header, invariant trio (streamed-skips-chain-but-file-saved,
untrustworthy-falls-back, nil-behaves-as-before), orchestrator failure → nil →
chain answers, no-key no-op, pre-open buffering. (16 in
AssemblyAIStreamingTests.)

## Contradictions found (reported, not improvised)

1. **The AssemblyAI key was NOT in the app's Secrets** — the brief said "the
   API key exists in the app's Secrets under the assemblyai slot per tbase
   set-key", but `tbase secrets` showed `assemblyai-api-key: MISSING` and
   `migrate-secrets` found nothing in the keychain. The key DID exist in the
   claude-secrets broker (`ASSEMBLYAI_API_KEY`, stored 2026-05-23) and was
   moved into the app's secrets file through the designed no-argv path
   (`claude-secrets run --inject … tbase set-key assemblyai --from-env …`).
2. **Item 1 has no dedicated commit.** Its finished changes
   (Transcription.swift, RecoveryChain.swift, LexiconTests.swift) were swept
   into the parallel app-session's commit `7f6d617` ("A4 wired…"), which used
   a tree-wide add while this session's item-1 commit was being prepared, and
   was pushed to origin before the collision was noticed. The content is
   intact and exactly as written (verified in `git show 7f6d617`); rewriting
   pushed shared history mid-flight was not an option. Items 2 and 3 are the
   dedicated commits `6161b26` and this one.
3. `tbase set-key`'s success message says "stored … in the login keychain" —
   it actually writes the 0600 secrets file (the keychain writer is legacy).
   Cosmetic; not fixed here to keep the diff on-scope.
4. Minor: the brief said "repo committed through f20d5f3"; HEAD was already
   `a8510a9` (and later `7f6d617`) from the parallel session. Expected under
   the two-session contract; all adds here are path-scoped to Core/Tests/docs.
