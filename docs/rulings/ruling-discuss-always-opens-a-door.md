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

Prod alone declares the durable product schemes; Dev keeps `tbdev` and TEST
keeps `tbtest`, so neither ever claims a real report. An old report therefore
always reaches Prod first. When another lane owns the panel, Prod forwards the
URL and exits, which is why forwarding is the mechanism here rather than a
backstop.

Amended 8 Sep 2026 before landing. As first written this section had both lanes
declare the product schemes, with the selected lane calling
`LSSetDefaultHandlerForURLScheme` on every launch. That was dropped for two
reasons: `scripts/audit-dev.sh` already asserts the Dev bundle owns only
`tbdev`, and claiming a handler rewrites a system-wide association for every
app on the Mac as a side effect of starting a development build. Forwarding
already makes the simpler arrangement correct, at the cost of one short-lived
process per click while a non-Prod lane is selected.

Discuss resolves the requested id against both stored Stops and live sessions.
Its routing policy is a pure Core function with regression tests for all three
destinations.
