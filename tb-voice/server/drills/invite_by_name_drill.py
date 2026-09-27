"""Inviting an agent by name, and the queue when no name is said.

27 Sep, from the bot's own log:

    22:39:41  gate p=0.93 invite_next :: Can you invite the SambaNova agent?
    22:39:41  {"event":"stage","name":"Document sharing and hub design"}

The gate was right -- there is one invite verb and this is it. The handler was
handed the sentence and never read it, so every "invite X" meant "invite
whoever is next", silently. And "whoever is next" was itself wrong: it sorted
unheard rows first, which meant hearing an agent changed who was next, and then
fell through to the live list in alphabetical order by working directory.

Ruled the same day: "it should be the same rules as for the grid today, bring
next agent." The grid's order now comes down the `targets` door
(ManagerJSON.gridBand), so the queue here is just "the first row that is not
already on stage".
"""
import asyncio, sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import manager as M

# The grid's order, as the door now returns it: the one asking for you first.
TARGETS = [
    {"sessionId": "aaaa1111", "name": "Document sharing and hub design", "project": "sharing"},
    {"sessionId": "bbbb2222", "name": "AI Voice Hackathon SambaNova planning", "project": "Projects"},
    {"sessionId": "cccc3333", "name": "Uvape report", "project": "kopi"},
    {"sessionId": "dddd4444", "name": "Landing page inspiration", "project": "kopi"},
]


async def main() -> int:
    fails = []

    def check(what, ok):
        print(f"   {'ok  ' if ok else 'FAIL'}  {what}")
        if not ok:
            fails.append(what)

    mgr = M.Manager.__new__(M.Manager)
    mgr.stage = None

    async def targets(self=None):
        return list(TARGETS)

    async def waiting(self=None):
        return [{"sessionId": "aaaa1111", "heard": False, "topic": "Six seams"}]

    mgr._targets = targets
    mgr._waiting = waiting

    named = await M.Manager._named_session(mgr, "Can you invite the SambaNova agent?")
    check("the name in the sentence picks that agent",
          named is not None and named["sessionId"] == "bbbb2222")

    # No name, so the queue: the grid's first row.
    plain = await M.Manager._named_session(mgr, "Can you invite the next speaker?")
    check("'the next speaker' names nobody", plain is None)
    nxt = await M.Manager._next_session(mgr)
    check("the queue is the grid's first row",
          nxt is not None and nxt["sessionId"] == "aaaa1111")
    check("and it carries the waiting row's topic for the announcement",
          nxt.get("topic") == "Six seams")

    # On stage is never invited again.
    mgr.stage = {"sessionId": "aaaa1111"}
    nxt = await M.Manager._next_session(mgr)
    check("the agent on stage is skipped", nxt["sessionId"] == "bbbb2222")
    mgr.stage = None

    # Short words cannot match: "the", "next", "agent" are in every sentence.
    check("short and common words do not name an agent",
          await M.Manager._named_session(mgr, "invite the next one") is None)

    # Two agents share "kopi" as a project; a tie is an ambiguity, not a pick.
    tied = await M.Manager._named_session(mgr, "invite the kopi agent")
    check("a tie names nobody, so the queue answers instead", tied is None)

    # A name that is not there falls through rather than inventing a match.
    check("an unknown name matches nothing",
          await M.Manager._named_session(mgr, "invite the Fermilab agent") is None)

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
