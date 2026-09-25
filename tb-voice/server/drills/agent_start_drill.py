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
    src = M.Manager._do_start_agent.__code__.co_consts
    text = "\n".join(str(c) for c in src if isinstance(c, str))
    body = M.inspect.getsource(M.Manager._do_start_agent) if hasattr(M, "inspect") else None
    if body is None:
        import inspect
        body = inspect.getsource(M.Manager._do_start_agent)

    fails = []

    def check(what, ok):
        print(f"   {'ok  ' if ok else 'FAIL'}  {what}")
        if not ok:
            fails.append(what)

    attempt = body.index('_earcon("listening")')
    run = body.index("_run(*argv")
    confirm = body.index('_earcon("returned")')

    check("the attempt is heard before the wait begins", attempt < run)
    check("and says which agent, so a mishearing is obvious now and not later",
          'self._say(f"Starting {name}.")' in body)
    check("the arrival is a different cue, after the command returns", run < confirm)
    check("and a failure has its own, because silence used to mean both",
          '_earcon("needsYou")' in body)
    check("the cues are ones the app already has",
          all(c in ("listening", "returned", "needsYou", "dispatched")
              for c in __import__("re").findall(r'_earcon\("(\w+)"\)', body)))

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())
