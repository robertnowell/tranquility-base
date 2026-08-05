# Rationale field: ruled, validated, ready to wire

For the session that owns `Summarizer.swift` / `SessionBrief` / `SpokenComposition`.
Robert ruled (05 Aug, in the WS-C session) and the prompt design is already
validated against the 10 most recent corpus records. This is the implementation
handoff, mirror of `docs/wiring-a4.md` in the other direction.

## The rulings

1. **Depth-1 (⌃⌃) is a dedicated, model-written field** — the card-field
   concatenation and its "The goal is …" glue are dead. The shape is literal:
   *"We propose X because Y. We need to be careful about Z."* — the why for the
   proposal by default, plus risks, plus state the recap had no room for.
   Economical, dense, accessible; a briefing, not another terse sentence.
2. **Card fields stay** (asterisked, revisit after the grid exists) — and the
   ablation below gives them a measured justification beyond the grid.
3. **The spoken/card contradiction is resolved**: spoken fields (recap,
   proposal, rationale) never name symbols/paths; card fields may, *because
   they are read, not heard*. The "goal/risk/question are also what the user
   hears" clause dies.

## Validated prompt

`tools/replay/prompts/vnext-b-rationale.txt` — vnext-a plus the rationale slot,
section, resolved card-field wording, and two examples with rationales.
Run: `tools/replay/runs/vnext-b-rationale/` (r0350–r0359).

Measured on those 10:
- rationale present 10/10, template shape held, why-content genuinely deepens
  (see r0354, r0359 — good), depth-0 discipline held (recap ≤12w maintained).
- **Defect 1 — length**: avg 83 words vs the 40–70 spec; r0358 hit 113.
  Fix in prompt (harder cap phrasing) AND enforce in composition:
  `SpokenComposition` clamps rationale via the sanitizer's `maxWords` exactly
  as depth-1 does today (~70, sentence-boundary drop).
- **Defect 2 — symbol leakage**: r0358 spoke `isCapturingAudio`, `Sources/`.
  Add one reinforcement line inside the rationale section ("speakability rules
  apply here with full force: no paths, no symbols, no hashes") — the
  sanitizer remains the backstop, but "a symbol" mid-briefing is mangling,
  not sanitizing.

## Ablation: are the card fields superfluous? No — measured

Robert asked whether goal/happened/nextStep/question/risk add anything.
`prompts/ablate-nocards.txt` (schema minus the five fields, rules otherwise
identical) vs vnext-a on r0350–r0359:

- 9/10 spoken outputs differ.
- vnext-a: recap avg 9.4w, proposal avg 10.7w, **0** budget violations.
- ablated: 11.5w / 11.2w, **2** violations — worst case r0358 ballooned to 47
  spoken words and spoke "StateLegend" (symbol leak).

Reading: the card fields are a **pressure-relief valve** — detail has a place
to drain, so the spoken lines hold budget. Remove them and the detail floods
the spoken channel. They earn their keep even before the grid renders them.

## Implementation checklist (your files)

1. Port `vnext-b-rationale.txt` into `Summarizer.systemPrompt` with the two
   defect fixes; keep slot mapping identical.
2. `SessionBrief` + `rationale: String?`; persist alongside the other fields
   (BriefStore column/migration as appropriate).
3. `SpokenComposition.depthOneSpokenText`: speak `rationale` when present
   (sanitized, clamped ~70 words, callsign prefix as today); the clause
   composition survives ONLY as fallback for pre-rationale rows — and the
   "The goal is" phrasing dies with it (fallback may speak the raw fields
   as sentences or the "No further rationale recorded" line; Robert hates
   the glue more than the fallback being plain).
4. Tests: prefers-rationale; fallback for old rows; clamp; symbol
   sanitization inside rationale.
5. Re-run the compare gates on r0350–r0359 before shipping (the A5
   discipline: eyeball 10 rationales for density + grounding).

App side (⌃⌃ handler) already speaks whatever `depthOneSpokenText` returns,
card + karaoke highlight included — zero app changes needed.
