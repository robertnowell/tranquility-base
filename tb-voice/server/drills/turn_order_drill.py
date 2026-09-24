"""Turns are decided in the order said, one at a time (hf-13).

A slow turn (a send: the span pick, the target lookup, the enroll) must finish
before the next is judged, and what was said meanwhile keeps its order. Since
compose mode was removed (24 Sep) there is no dictation state to route by; the
property left is order and exclusion, which is what the queue is for.

    TB_HOSTED=1 uv run python drills/turn_order_drill.py
"""

import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import session  # noqa: E402
from manager import JevClient, Manager  # noqa: E402

failures: list[str] = []


def check(ok: bool, what: str):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


async def main():
    session.bind()
    m = Manager(JevClient("drill-key-unused"))
    log: list[tuple] = []
    running = {"n": 0, "max": 0}

    async def fake_turn(text, frame, direction):
        running["n"] += 1
        running["max"] = max(running["max"], running["n"])
        log.append(("start", text))
        if text.startswith("send a message"):
            await asyncio.sleep(0.3)  # the span pick, the target lookup, the enroll
        running["n"] -= 1
        log.append(("end", text))

    m._handle_turn = fake_turn
    worker = asyncio.create_task(m._turns.run())

    m._turns.put(("send a message to Mailchimp.", None, None))
    await asyncio.sleep(0.05)
    m._turns.put(("The Back to School sends look stuck in draft.", None, None))
    m._turns.put(("And the discount code expired.", None, None))
    await asyncio.wait_for(m._turns.drained(), 5)
    worker.cancel()

    starts = [text for ev, text in log if ev == "start"]
    for t in starts:
        print("  ", t)
    check(starts == ["send a message to Mailchimp.", "The Back to School sends look stuck in draft.",
                     "And the discount code expired."], "turns are handled in the order said")
    check(log.index(("end", "send a message to Mailchimp.")) < log.index(("start", "The Back to School sends look stuck in draft.")),
          "the slow turn finishes before the next is judged")
    check(running["max"] == 1, "never two turns at once")

    # One failing turn never stops the ones behind it.
    boom = {"hit": False}

    async def failing(text, frame, direction):
        if not boom["hit"]:
            boom["hit"] = True
            raise RuntimeError("a turn that fails")
        log.append(("start", text))

    m._handle_turn = failing
    worker = asyncio.create_task(m._turns.run())
    m._turns.put(("first.", None, None))
    m._turns.put(("second.", None, None))
    await asyncio.wait_for(m._turns.drained(), 5)
    worker.cancel()
    check(("start", "second.") in log, "a failed turn does not stop the next one")

    print(f"\n{'FAIL' if failures else 'PASS'}: {len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


asyncio.run(main())
