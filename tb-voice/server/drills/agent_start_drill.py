"""Starting an agent says so at once, and again when it is actually there.

`tbase new` is allowed seventy-five seconds. Until it returned the room was
silent, so a start that was working and a start that had not been heard sounded
identical — and the only way to find out was to wait a minute and see.

Three moments now, and they are different sounds: the attempt, the agent
arriving, and the failure. The failure had no cue at all, which meant the worst
case was also the quietest.
"""
import asyncio, sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import manager as M


def main() -> int:
    import inspect
    import re

    body = inspect.getsource(M.Manager._do_start_agent)
    fails = []

    def check(what, ok):
        print(f"   {'ok  ' if ok else 'FAIL'}  {what}")
        if not ok:
            fails.append(what)

    # Asserted as an ORDER of cues, not against the name of whatever call
    # happens to start the agent. The first version of this drill asserted on
    # `_run(*argv` and broke the day that moved into a helper, which is a drill
    # failing for the one reason a drill must not: the implementation changed
    # and the promise did not.
    cues = re.findall(r'_earcon\("(\w+)"\)', body)
    attempt = body.index('_earcon("listening")')
    spoken = body.index('self._say(f"Starting {name}.")')
    arrival = body.index('_earcon("returned")')

    check("the attempt is heard first of all", attempt == min(attempt, spoken, arrival))
    check("and says which agent, so a mishearing is obvious now and not later",
          spoken < arrival)
    check("the arrival is a different cue, and comes after", attempt < arrival)
    check("a failure has its own, because silence used to mean both",
          "needsYou" in cues)
    check("three cues and no more, so none of them is ambiguous", len(set(cues)) == 3)
    check("the cues are ones the app already has",
          all(c in ("listening", "returned", "needsYou", "dispatched") for c in cues))

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())
