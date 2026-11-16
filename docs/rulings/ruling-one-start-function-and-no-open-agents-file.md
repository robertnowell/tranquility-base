# One start function, and no file that lists open agents

Ruled 14 Nov 2026, on the page `liveness-architecture-review` (review session
8f96df4b, which read the code and changed no file). Robert answered "agree" to
both recommended options. They bind the work that follows the 11 Nov ruling:

> "If I go to interact with them and it's not alive, then it revives it, and
> then sends the message. The user shouldn't have to care about that."

Status: RULED, NOT BUILT. Both rulings apply before the microphone step.

## Ruling 1: every start goes through one function

There is one function that starts the process of an agent that has none. Every
door calls it. Nothing that starts a process is written beside it.

The callers are: the revive tap, Go to Agent, a reply, the open microphone,
and `tbase revive`. The tap keeps only its announcements.

`GoneStart` (the unmerged reply work, commit `e02a9856`) becomes that
function, and `AppDelegate.revive` calls it. The reply code does not merge as
a second copy of the tap.

**Why.** The reply code repeated the tap's gates and missed one of them. Two
doors with two definitions of "gone" is how one of them starts a second
process. Measured in the code on 14 Nov:

- `ResumeGuard.claim` reads only `inFlight`. `ResumeGuard.beginIntent` reads
  `inFlight` and `intents`. `GoneStart` does not call `beginIntent`. So a tap
  followed by a reply can both proceed, and the reply shows a false "Couldn't
  start" card. This is the 21 Sep race again (tapped 13:56:41, claimed later).
- The tap waits 8 s for the process to register. `GoneStart` waits 30 s.
- The tap records `agent_revived`. The reply records
  `reply_started_process`. A falling revive count then proves nothing.
- Only `GoneStart` checks `verifiedCurrent`.
- `GoneStart` refuses a Codex agent with "not a Claude Code session".

**What the one function must have.**

1. The intent reservation: `ResumeGuard.beginIntent` at the door, and
   `isInFlight` for a second caller, which then waits for the first start.
2. The Codex path (`attemptCodexResume`, `adoptRunningCodex`) in place of the
   refusal. Branch on what the harness can do
   (`capabilities.registersWithLiveness`), not on the harness id.
3. One registration wait, used by every caller.
4. One result event, with a `via` field that names the caller.
5. One decision on `verifiedCurrent`, applied to every caller.
6. A failed `ps` scan is "unknown". It never becomes a refusal card.

The shape the review proposed, as the smallest structural correction:
`ensureRunning(id) -> running(pane) | started(pane) | unknown(why) | refused(why)`.

**One hazard measured after the ruling (12 Nov, Claude Code 2.1.322).** A
hand-started agent (`claude`, `claude -c`) never has its session id in its
command line, so the `ps` scan in `ResumeGuard.claim` cannot see it. The
registry listed it in 4 of 4 tries, within 0.38 s of process start. A process
standing on a dialog before it registers could not be reproduced, so that
case is not measured. Before an automatic start, the function looks for a
harness process in the agent's directory that the registry does not list, and
does not start if it finds one.

## Ruling 2: no new file that lists open agents

"Open" stays derived. An agent is open when all three are true:

- its transcript exists,
- the lamp switch files do not say off,
- its last turn is inside the limit (`SessionRow.openFor`).

No step of the plan adds a persisted open-agents record. The record was in
the earlier plan, and this ruling removes it.

**Why.** A second record of the same fact drifts from the first. The grid
change (PR #788, `e3a2ca3b`) shows the derived rule is enough: before it, the
grid after a restart held 8 agents aged 37.7 to 42.0 days. After it, the grid
held 8 agents aged 0.0 to 0.6 days. No new file was needed.

## Not ruled yet. Do not guess these.

- The 7 day limit itself. Release 0.3.1508 uses it as a default.
- The lamp for an agent whose turn a restart stopped. The review recommended
  green.
- What the speech queue does for an agent that has no process.
- Removing the words "revive" and "gone" from what the user sees and hears.

## Repairs owed before the reply change merges

From the page `liveness-progress-audit` (session 8f96df4b):

- The switch is reversed, so the change is off by default.
- A sound plays when a start begins.
- A drill covers the empty grid after 8 or more days.

## Corrections to the record

The 12 Nov page said the grid after a restart draws "newest first". That is
true of which agents are picked (`ProjectLayout.gridRows`). The panel then
draws them in the user's folder order (`ProjectLayout.arrange`).
