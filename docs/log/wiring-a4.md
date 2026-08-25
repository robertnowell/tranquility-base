# Wiring A4: ⌃⌃ → spoken depth-1 (rationale + risk)

For the session that owns `main.swift`. Everything Core-side is committed (09cb796)
and dormant; this is the one call site. The detector already fires — every press
currently logs `depth-1 pull: not yet implemented — WS-A` (main.swift:629).

## The change

In the `.controlDoubleTapped` handler, replace the stub log with:

1. Resolve the announcement to explain: the one currently speaking, else the most
   recently spoken (whatever main.swift already tracks as the active/last
   announcement — the same object `hud` is showing).
2. Speak `SpokenComposition.depthOneSpokenText(for: announcement)` through the
   normal speech chain. The function is total: sanitized, ≤25-word body,
   callsign prefixed exactly once, and returns "No further rationale recorded."
   when the card fields are empty — no nil-handling needed at the call site.
3. No panel transition is required — this is pure speech; the karaoke highlight
   may follow it or not, your call under the arbiter. If nothing has been
   announced yet this launch, speak nothing and log (or speak the fallback —
   your call; the quiet option matches "the voice is the away-channel").
4. Optional but free: `store.recordDogfood(.depthOnePulled, sessionId: …)` —
   the counters table (v5 migration) is live and `tbase dogfood` reports it.

## Interaction with the arbiter

Speaking depth-1 during `.speaking` should interrupt/duck the current utterance
the same way ⌃⌥-next does today (speech.stop() then speak) — but note the lesson
of 18:30:30: the announce task will resume `.interrupted` when you stop its
speech. Under your legality table that resume is refused while capture holds the
stage; for depth-1 (not a capture state) decide explicitly whether the resume
may repaint or whether depth-1 speech should hold the stage until done.

## A2 (hail) — NOT this wiring

`Announcement.hailText` is also committed and dormant, but wiring the hail
changes the ambient announce flow itself (speak hail only; summary waits for
⌃⌥). That's a flow change, not a call site — coordinate before wiring; the
spec's SPEAKS bullet (vd-state-legend-page, PNL 01) is the contract.
