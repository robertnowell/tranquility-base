# The brief is written in the order it is spoken

Ruled 14 Sep 2026, after a live ladder said the goal twice and the prompt
that produced it was read back field by field against the code that consumes
it.

## The ruling

The summariser returns two objects. `spoken` holds what the listener will
hear, written by the model in the order it will be heard: recap, proposal,
goal, findings, solution, rationale. `written` holds what the hub page shows:
headline, deck. Nothing else. There is no risk field; a risk belongs inside
the rationale. There are no card fields; the panel never showed a card.

Every spoken field says something the fields before it did not. A field with
nothing new is null, and a null field is not spoken. The ladder is never
padded: if there is no rationale, there is no WHY rung.

The prompt does not ask the model to open with the project label, and no code
strips a label off a fresh summary. The prompt does not mention callsigns.

## Why this is a context ruling, not a gate

Three gates had grown around this prompt, each accommodating something the
prompt itself caused:

- the WHY rung's fallback (5 Aug) recited goal, risk and question when the
  rationale was null, and once GOAL became a rung of its own (19 Aug) it spoke
  the goal twice on thirty-eight percent of ladders;
- a label strip (18 Aug) removed the project label the prompt demanded the
  model open with;
- a "one staged briefing" rewrite (7 Sep, never landed) asked the model to
  null fields that echoed others, which would have fired the fallback more.

The measured fact underneath all three: over 1,006 briefs in a week, the model
never once repeated the goal inside a rationale. The repetition was ours. The
repair is to tell the model what will be spoken and in what order, show it two
real turns of the right length, and stop composing on its behalf.

## What moved in code

- `AnthropicSummaryProvider.systemPrompt`: rewritten, about a third of the
  length. The goal section keeps its measured examples.
- `AnthropicSummaryProvider.parse`: reads the nested shape; still reads the
  flat shape, because the managed gateway composes its own briefs and has not
  moved yet.
- `SpokenComposition.whyRung`: the rationale or nil. `depthOneSpokenText` and
  its fallback are gone.
- `Coordinator.strippingModelLabels`: gone. The restore path keeps its strip
  for rows written before this date, which have the label baked in.

## Evidence

`tbase replay-log --dry` prints the compiled prompts for real turns; without
`--dry` it sends them through the production call. Ten turns before and after
are on the agent hub page "What the summariser is told".
