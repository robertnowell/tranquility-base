# Rationale field: ruled, validated, ready to wire

For the session that owns `Summarizer.swift` / `SessionBrief` / `SpokenComposition`.
Robert ruled (05 Aug, in the WS-C session) and the prompt design is already
validated against the 10 most recent corpus records. This is the implementation
handoff, mirror of `docs/log/wiring-a4.md` in the other direction.

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

`tools/replay/prompts/vnext-d-target30.txt` (lineage: vnext-b → c → d) — vnext-a plus the rationale slot,
section, resolved card-field wording, and two examples with rationales.
Run: `tools/replay/runs/vnext-b-rationale/` (r0350–r0359).

RE-RULED 05 Aug: **budget is 40 words, hard.** Three calibration rounds on
the same 10 records (prompt-stated budget → measured average):

| prompt says      | avg | max | template "We propose" |
|------------------|-----|-----|-----------------------|
| 40–70 (vnext-b)  | 83  | 113 | mostly                |
| 40 max (vnext-c) | 52  | 72  | slipped (r0354)       |
| ~30 (vnext-d)    | 50  | 62  | **10/10**             |

Haiku's verbosity floor for this content is ~50 words regardless of the
stated number — the prompt AIMS, it cannot enforce. Therefore:
- Port **vnext-d-target30.txt** (its rationale section pins the template:
  "ALWAYS open with 'We propose'").
- **The clamp is the enforcement**: `SpokenComposition` cuts the rationale at
  40 words on a sentence boundary. The sacrifice order is automatically
  right — "We propose X because Y" is always the first sentence, "careful
  about Z" second, leftovers last.
- **Symbol leakage recurs stochastically** (r0358 spoke `Sources/` in one
  round, clean the next): the sanitizer backstop on the rationale is
  MANDATORY, not defense-in-depth. Same pass the spoken sections get.

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
