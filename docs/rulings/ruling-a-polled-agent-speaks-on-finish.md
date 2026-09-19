# A polled agent says what it did, and the lamp waits for it

**Ruled 15 September 2026.**

> "We fetch on finish. The lamp stays blue while we fetch. We get the last
> turn, we summarize and make the ladder, then we turn the lamp green.
> Inviting the agent to speak opens the agent card. For crobot, the open
> report goes to crobot's web UI."

## The gap

A streaming provider (OpenCode over SSE, ACP over stdio) emits `.said` with the
agent's words as they arrive, so the brief, the summary, the spoken card and
the hub page all fill up. A **polled** provider (crobot) only yields `.changed`
— a poll sees *that* the state moved, never *what was written*. So a finished
crobot task reached the panel as a bare "it finished" and a link. Robert:
*"it's not the full experience."*

## The rule

1. **Fetch on finish, and only on finish.** A turn ending is the one
   transition with a recap worth hearing. One fetch per finished turn, never
   per poll; a mid-turn "it's working" needs no transcript.

2. **Read the last agent turn.** Enough for a summary and a hub page, and it is
   what "here's what it just did" means. Not the whole transcript — that is more
   than the recap needs and more calls against the gateway.

3. **The lamp holds blue until the recap is ready.** A finished turn is not the
   user's turn until there is something to hand them. So the finished state is
   not merged into the panel until the words are fetched: the row keeps its
   working lamp through the fetch — a cold-sandbox wake simply keeps it blue a
   little longer, which is the truth — and turns green in the same beat the
   words become readable, never before.

4. **One stop event, carrying the words.** The fetched turn REPLACES the
   wordless finish event rather than adding to it, so there is a single card,
   now with a recap. A finish whose transcript reads empty keeps its bare
   finish line, so the lamp still lights — just without a recap.

5. **The door is "go deeper," not the only thing.** Inviting the agent to speak
   opens its card with the recap on the stage, the same as a local agent. The
   web page stays as the door for crobot's own view — the report opens there,
   one tap past the recap, exactly as a local agent's terminal is one tap past
   its summary.

## Where it lives

`AgentPoller.withTheirLastWords` fetches and replaces on finish;
`pollOnce` fetches before merging the finished state, which is what holds the
lamp blue. Nothing downstream changed: a `.said` line already becomes a brief,
a summary, speech and a hub page. The rule only makes the polled agents reach
that pipeline the streaming ones were already in.
