"""Turns are decided in the order said, and dictation is recognised on arrival
at the head of the queue, not at arrival on the wire (hf-13).

The case that broke: "send a message to Mailchimp" opens a message, but it
takes a Jev call and a target lookup to get there. The user keeps talking. The
next sentence used to be dispatched the moment it arrived, while the open
message did not exist yet, so it went through the command gate. Here the first
turn opens the message after 300 ms, the second arrives 50 ms in, and the
second must be handled as dictation, after the first, never alongside it.

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
        log.append(("start", "command", text))
        if text.startswith("send a message"):
            await asyncio.sleep(0.3)  # Jev, the target lookup, the enroll
            m.open = object()  # the message is open now
        running["n"] -= 1
        log.append(("end", "command", text))

    async def fake_compose(text, frame, direction):
        running["n"] += 1
        running["max"] = max(running["max"], running["n"])
        log.append(("start", "dictation", text))
        await asyncio.sleep(0.01)
        running["n"] -= 1
        log.append(("end", "dictation", text))

    m._handle_turn = fake_turn
    m._compose_turn = fake_compose
    worker = asyncio.create_task(m._turns.run())

    m._turns.put(("send a message to Mailchimp.", None, None))
    await asyncio.sleep(0.05)
    m._turns.put(("The Back to School sends look stuck in draft.", None, None))
    m._turns.put(("And the discount code expired.", None, None))
    await asyncio.wait_for(m._turns.drained(), 5)
    worker.cancel()

    starts = [(kind, text) for ev, kind, text in log if ev == "start"]
    for s in starts:
        print("  ", s)
    check(starts[0] == ("command", "send a message to Mailchimp."), "the send request is handled first")
    check(starts[1][0] == "dictation", "the sentence said while the message was opening becomes dictation")
    check([t for _, t in starts[1:]] == ["The Back to School sends look stuck in draft.",
                                         "And the discount code expired."], "dictation keeps the order it was said in")
    check(running["max"] == 1, "never two turns at once")

    # One failing turn never stops the ones behind it.
    m.open = None
    boom = {"hit": False}

    async def failing(text, frame, direction):
        if not boom["hit"]:
            boom["hit"] = True
            raise RuntimeError("a turn that fails")
        log.append(("start", "command", text))

    m._handle_turn = failing
    worker = asyncio.create_task(m._turns.run())
    m._turns.put(("first.", None, None))
    m._turns.put(("second.", None, None))
    await asyncio.wait_for(m._turns.drained(), 5)
    worker.cancel()
    check(("start", "command", "second.") in log, "a failed turn does not stop the next one")

    print(f"\n{'FAIL' if failures else 'PASS'}: {len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


asyncio.run(main())
