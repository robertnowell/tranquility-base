# The isolation drill

Two questions, one agent that is never the manager.

**Does this platform reset the Python process between sessions?** It does not.
Measured 22 Sep 2026 on Pipecat Cloud: seven sessions were served by two
long-lived processes round-robin, and a module-level list in one of them grew
to hold all five session ids it had seen, with uptime climbing 98 s to 130 s
across the run. So any name at module scope in the bot is shared by every
session that instance serves. That is the whole of hf-1: the manager's
`EXCHANGE` is exactly such a name.

**Why its own agent?** Because a drill run against `tranquility-manager` lands
in the same warm process as the real sessions, and its turns then appear in the
user's context. That is how the leak was found. `drill.py` refuses to run
against the manager by name.

## Running it

```sh
cd tb-voice/server
uv run python drills/isolation/drill.py              # deploy, 4 sessions, delete
uv run python drills/isolation/drill.py --count 8    # more sessions
uv run python drills/isolation/drill.py --keep       # leave it up
```

It deploys `isolation-drill` from this directory, buys sessions through the
public start endpoint with the dev shim's key (`~/.claude/hq.json`, or
`PCC_KEY`), reads one probe line per session, prints the verdict, and deletes
the agent. About three minutes, one deploy.

Output of the run that settled it:

```
  session 1  boot b560ef5efce7  count 2  up   98.3 s  start  174 ms
  session 2  boot d8f46315a487  count 2  up  102.0 s  start  179 ms
  session 3  boot b560ef5efce7  count 3  up  105.3 s  start  234 ms
  session 4  boot d8f46315a487  count 3  up  109.0 s  start  163 ms

✓ 4 sessions, 2 process(es)
    b560ef5efce7: 2 session(s), module count reached 3
    d8f46315a487: 2 session(s), module count reached 3

! module state SURVIVES a session boundary on this platform
```

## Two things that surprised us

- **`--max-agents 1` is not one process.** After redeploying with a cap of one,
  two instances kept serving, alternating. Nothing may assume instance count
  equals process count.
- **Warm reuse is what buys the fast start.** Session start stayed between 163
  and 256 ms across every run. That is the reason the platform reuses, and the
  reason this is not a bug to report but a property to design around.

## What this drill is not

It does not test the manager. The manager's own regression test is the next one
to write: deploy the manager image under a drill name, speak one distinctive
sentence in session 1, and assert session 2's first classifier call carries
none of it. This drill is the harness that makes that safe to run.
