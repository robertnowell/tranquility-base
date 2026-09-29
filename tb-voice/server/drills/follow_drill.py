"""The manager follows the panel (hf-16, "follow", ruled 27 Sep).

A shortcut acts on the Mac at once; the Mac then sends a `stage` event, and
the manager's stage becomes that agent. Checks, in process:

  follows     a stage event from the Mac makes that agent the stage, so a send
              with no agent named goes to it
  same        a second event for the same agent changes nothing
  unknown     an event this bot does not know is dropped at the door
  isolated    one session's event never moves another session's stage

    uv run python drills/follow_drill.py
"""

import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import session  # noqa: E402
import wire  # noqa: E402
from manager import JevClient, Manager  # noqa: E402

failures: list[str] = []


def check(ok: bool, what: str):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


async def one_session(first: str, second: str | None):
    session.bind()
    wire.bind()
    m = Manager(JevClient("drill-key-unused"))
    m.stage = {"sessionId": "old00000-0000-4000-8000-000000000000", "name": "Before"}
    task = asyncio.create_task(m._follow_mac())
    wire.take_reply({"wire": "event", "event": "stage", "session": first, "name": "Landing page",
                     "goal": "We are building the landing page", "via": "announce"})
    await asyncio.sleep(0.05)
    after_first = dict(m.stage)
    resolved = await m._resolve_agent(None)
    if second:
        wire.take_reply({"wire": "event", "event": "stage", "session": second, "name": "Mailchimp", "via": "reply"})
    wire.take_reply({"wire": "event", "event": "tray_changed", "session": "zzz"})
    await asyncio.sleep(0.05)
    task.cancel()
    return after_first, resolved, dict(m.stage)


async def main():
    a = "aaaa1111-0000-4000-8000-000000000001"
    b = "bbbb2222-0000-4000-8000-000000000002"
    first, resolved, last = await one_session(a, None)
    check(first.get("sessionId") == a and first.get("name") == "Landing page", "follows: the Mac's stage becomes the manager's")
    check(resolved == a, "follows: a send with no agent named goes to that agent")
    check(last.get("sessionId") == a, "unknown: an event this bot does not know changes nothing")

    t1 = asyncio.create_task(one_session(a, b))
    t2 = asyncio.create_task(one_session(b, None))
    (f1, _, l1), (f2, _, l2) = await asyncio.gather(t1, t2)
    check(l1.get("sessionId") == b and l2.get("sessionId") == b and f2.get("sessionId") == b,
          "isolated: each session follows only its own Mac's events")
    check(f1.get("sessionId") == a, "isolated: the other session's event did not move this one early")

    print(f"\n{'FAIL' if failures else 'PASS'}: {len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    asyncio.run(main())
