# Discuss always opens a door

Ruled 7 Sep 2026 from a live failure on `why-partitions-at-all.html`.

## The incident

"Discuss with agent" was clicked twice while the report's agent was still
working on its first turn. The click reached Tranquility Base, but the app found
no completed Stop for that session and called it unknown. More importantly,
LaunchServices sent the URL to the other installed bundle: that new process drew
an error card, lost the shared singleton lock, and exited about 50 ms later. From
the operator's chair, both clicks did nothing.

## The ruling

**Discuss always opens the best door that exists now.**

- A completed turn opens the speak-to-agent card, even if the agent is already
  working on another turn.
- A live agent with no completed turn opens its tmux session. This is the same
  meaning a blue mid-turn row already has in the grid: there is no finished turn
  to summarize, and the terminal is where the work can be seen.
- An agent absent from this Mac opens the existing invitation or a visible
  explanation. There is no silent outcome.

The card remains the normal Discuss behavior. Tmux is the first-turn fallback,
not a replacement for conversation history.

## What changed

Deep links are now queued until launch completes. When LaunchServices chooses a
second Prod/Dev bundle, the process that loses the shared ownership lock forwards
its URLs to the process that owns the panel before exiting. Only that owner acts.

Prod and Dev both declare the durable product schemes. On launch, the selected
lane makes itself their default handler; switching lanes changes the handler
back as part of starting that lane. Thus an old report goes directly to the app
the operator selected, while forwarding remains a backstop for a stale routing
decision or a launch race. TEST owns only `tbtest` and never claims real reports.
The Dev bundle audit pins that exact contract: the two durable schemes followed
by its private `tbdev` scheme, with no unreviewed fourth registration.

Discuss resolves the requested id against both stored Stops and live sessions.
Its routing policy is a pure Core function with regression tests for all three
destinations.

## Amended 9 Sep 2026: Discuss is the row's tap

Measured on `paseo-cloud.html`, 9 Sep 20:55. The report's Codex agent had
finished on 8 Sep and exited. Discuss found a completed turn, opened the card,
spoke it, and stopped: no GO TO AGENT (no pid), no revive (the card has no such
door), and a reply from that card would have failed after the 12 s readiness
grace. Tapping the same row in the grid revives the agent. The 7 Sep rule read
"completed turn" before it read liveness, so the process was never consulted.

**Discuss does exactly what tapping that agent's row in the grid does.**

- The deep link builds the same rows the grid and Past Agents are built from,
  finds the session's row, and runs `SessionRow.action(for:)` through the same
  calls a row tap makes: green announces, every other live lamp opens the
  terminal, a proven-dead revivable row revives, an unproven unlit row refuses
  out loud.
- A session with no row (out of the scan window, headless, never on this Mac)
  keeps the 7 Sep fallback: a recorded turn is a card, nothing recorded is the
  invitation.
- Every outcome logs which way it went. The card branch used to be the only
  silent one, which is why a correct outcome read as "it did nothing".

The deep-link rule stands: nothing here records, sends, or types. A revive
starts a process in a pane, which the grid's tap already does on one click.
