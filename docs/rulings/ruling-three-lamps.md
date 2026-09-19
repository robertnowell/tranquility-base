# Three lamps, and there is no fourth

**Ruled 14 September 2026.** Supersedes every earlier description of a quiet or
neutral agent state. Newest ruling wins (CLAUDE.md rule 4), and this one cites a
measurement.

> *"Any lamps turned on, that is to say agents that are in the grid, are either
> green, blue, or amber. There's nothing else."*

> *"The only way to get to gray, or AKA idle, is if I turn off the lamp."*

---

## The rules

1. **An agent on the grid wears green, blue or amber.** There is no fourth lit
   lamp. No quiet socket, no neutral, no "alive with nothing to say".

2. **Green is your turn.** A question waiting on your judgment, something it
   said that you have not read, or a turn that finished and is standing by for
   the next one. All three are the same instruction to the user, so they are one
   lamp. *"For something needs your judgment is great. That's like it needs you.
   It's your time to shine."*

3. **Blue is its turn.** Chewing on the last thing you said.

4. **Amber is the unanticipated.** Auth expired, the provider refused, the run
   failed, nobody can reach it. **Amber is not the question channel** and never
   was: a question is green. Amber is a thing that has to be repaired before the
   agent can go on at all.

5. **There is no red lamp.** Asked directly on 14 Sep and answered: *"There is
   no red lamp. Absolutely not."* The web apps' red does not come across.

6. **The grey circle is the user's word and nobody else's.** An agent cannot put
   itself there. No provider status, no exit code, no timeout, no vendor's own
   spelling of "idle" may render as switched-off. The empty circle means one
   thing: the user clicked the lamp off.

7. **Greyed out means the process is gone and revival is the tap.** Distinct
   from 6: 6 is a filed agent that is still running, this is an agent that is
   not. *"If the agent is turned off completely, like I have killed the process,
   then it goes to grayed out, like revival."*

8. **A vendor's own word `idle` is GREEN.** crobot says `idle` when the sandbox
   is up and the turn is over, which is exactly rule 2's third case. Mapping a
   vendor's idle toward the dark end of the panel puts an agent's own state in
   the position reserved for the user's switch, which is rule 6's violation and
   was the defect that kept every crobot task off the panel for a week.

9. **Unknown is not a first-class answer.** *"Unknown is not a first-class
   answer. Like, it's either working, it's finished your turn, or there's an
   issue and they need to get some user's attention."* Where a provider looks
   silent, read its status feed before asserting ignorance. Genuine silence — a
   failed poll, a provider nobody can reach — is amber under rule 4, because it
   is a thing the user has to fix.

10. **Read-state is not an input to the lamp.** Two monotonic watermarks over an
    append-only log. It orders rows and it bolds them. It never colours one.
    `AgentPresentation.bucket` has no parameter to pass it through, and
    `AgentSessionTests.testTheLampCannotSeeReadState` fails if one comes back.

---

## What this cost, measured

Against the real panel on 14 Sep 2026, 225 rows:

| | before | after |
|---|---|---|
| green | 200 | 223 |
| blue | 1 | 1 |
| amber | 0 | 0 |
| **quiet socket** | **23** | **1** |
| unlit | 1 | 0 |

Every one of the 23 quiet rows was remote. **The fourth lamp was not a local
convention this band adopted; it was invented by this band.** The local grid had
been keeping rule 1 all along, and the remote band broke it on arrival. The one
survivor is a local row (`ce83316d`) and is tracked separately.

The crobot task went `unlit` to `ready` on this change alone.

## Two defects this ruling closed

**`.unknown` was an unread route, not honesty.** `OpenCodeClient.sessions` hard
-coded `state: .unknown` with a comment arguing that a local server does not
report a state. The premise was false: `GET /session/status` answers exactly
that, returns `{}` when the server is idle, and crobot's own gateway has been
reading it all along (`gateway/src/opencode.ts`, `busySessions`). Asserting
ignorance beside an endpoint that answers painted 22 working sessions amber.

**Read-state was gating colour.** Remote green required *unread*; unread
required a spool line; `RemoteSpool.lines` returns `[]` on first sighting. So a
crobot task could never be unread, never be green, and sorted below 200 local
rows into a part of the grid that is never drawn.

## Still open

Colour was never the only reason remote agents are invisible. With 23 live local
agents and a 12-slot grid, they lose on ORDERING under any rule that does not
privilege them, and 201 of the 223 green rows have no live process. That is a
separate decision and it is not settled here.
