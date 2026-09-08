# The brief is one message

Ruled 7 Sep 2026 after a live update gave the same answer for its goal and its
why.

## The ruling

The summary model is composing one user-facing briefing revealed in stages,
not filling a collection of unrelated fields.

The stages are explicit in the prompt:

1. the immediate spoken message;
2. the visible card;
3. the on-demand depth ladder;
4. the durable page header.

Each optional field earns its place by adding information at the point where
the user encounters it. If it would duplicate another field, it is `null`.
Close paraphrases count as repetition too. A required field is rewritten for
its distinct job rather than copied. The model must not invent detail merely to
make two fields look different.

A carried goal is the exception in authority, not in presentation: it remains
verbatim because it is session state. An optional field that would only echo
that goal is omitted.

## Why this lives in the prompt

A repository-side string matcher could suppress byte-identical values, but it
would miss the same thought with slightly different wording. Expanding it to
semantic matching would add another inference system after the model and make
publication behavior harder to understand. The model already has the source,
the intended role of every field, and the ability to edit the whole draft.

The prompt therefore performs the editorial pass before returning JSON. There
is no runtime deduplication table and no list of special field pairs.

## Evidence

`GoalRungTests.testThePromptBuildsOneStagedBriefingAndOmitsRepetition` pins the
four stages in publication order and the general omit-or-rewrite rule. It also
pins the carried-goal exception so a future cleanup cannot solve repetition by
discarding the session's stable aim.
