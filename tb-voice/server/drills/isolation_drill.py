"""Two sessions through one process share nothing.

22 Sep: 4 of 7 hosted sessions on one Mac opened with a previous session's turns
in the exchange, because the manager's memory was a module global and Pipecat
Cloud runs sessions back to back in one warm process. This runs two sessions the
way bot.run_bot does (bind, then tasks) in one process, one after the other and
then at once, and fails if either can see the other's exchange, echo state or
Notes agent. It also checks the `said` line carries the whole utterance (hf-20).

    TB_HOSTED=1 uv run python drills/isolation_drill.py

Run the live bot with TB_STRICT_SESSION=1 for warm_process_drill.py too, so
any read outside a session fails the drill instead of logging once.
"""

import asyncio
import io
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import events  # noqa: E402
import session  # noqa: E402
import wire  # noqa: E402
from echo import EchoGate  # noqa: E402
from manager import exchange_lines, note  # noqa: E402

LONG = "Tell the Mailchimp agent the Back to School sends look stuck in draft " * 4
failures: list[str] = []


def check(ok: bool, what: str):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


async def a_session(name: str, lines: int, hold: asyncio.Event | None = None) -> dict:
    """One session as run_bot starts it: bind first, then the work runs in
    tasks the session created, the way the pipeline's handlers do."""
    wire.bind()
    s = session.bind()
    seen_at_start = list(exchange_lines(12))

    async def handler():
        for i in range(lines):
            note("you", f"{name} line {i}", "silent")
            if hold is not None:
                await asyncio.sleep(0)  # interleave with the other session
        s.bot_voice["speaking"] = name == "A"
        s.external_until["t"] = time.monotonic() + (60 if name == "A" else 0)
        s.notes_sid = f"notes-{name}"

    await asyncio.create_task(handler())
    return {"start": seen_at_start, "end": list(exchange_lines(12)), "session": s,
            "gated": EchoGate().gated(), "said": s.said}


async def main():
    os.environ.setdefault("TB_HOSTED", "1")
    buf = io.StringIO()
    events._sink = buf  # capture the event lines instead of stdout

    # Back to back, as a warm instance hands over.
    a = await asyncio.create_task(a_session("A", 5))
    b = await asyncio.create_task(a_session("B", 2))
    check(a["start"] == [], "A starts with an empty exchange")
    check(b["start"] == [], "B starts with an empty exchange after A ran in the same process")
    check(all("A line" not in x for x in b["end"]), "B never sees A's turns")
    check(b["said"] == 2, "B numbers its own lines from 1")
    check(a["gated"] and not b["gated"], "A's voice does not gate B's microphone")
    check(b["session"].notes_sid == "notes-B", "B has its own Notes agent")

    # At the same time, as concurrent sessions on one instance would.
    hold = asyncio.Event()
    c, d = await asyncio.gather(a_session("C", 6, hold), a_session("D", 6, hold))
    check(all("D line" not in x for x in c["end"]), "concurrent C never sees D's turns")
    check(all("C line" not in x for x in d["end"]), "concurrent D never sees C's turns")

    # hf-20: the whole utterance reaches the app, not 120 characters of it.
    wire.bind()
    session.bind()
    note("you", LONG, "dictated")
    said = [json.loads(ln) for ln in buf.getvalue().splitlines() if '"event":"said"' in ln]
    last = said[-1] if said else {}
    check(last.get("text") == LONG.strip(), f"`said` carries all {len(LONG.strip())} characters")
    queued = wire.outbox().get_nowait() if not wire.outbox().empty() else {}
    check(queued.get("event") == "said" and queued.get("text") == LONG.strip(),
          "hosted, the `said` line is queued for the wire")

    # hf-22: a read outside a bound session is never quiet. In a fresh context
    # (as a task started before bind would see it), strict mode raises.
    import contextvars
    os.environ["TB_STRICT_SESSION"] = "1"
    try:
        contextvars.Context().run(session.current)
        check(False, "an unbound session read raises in strict mode")
    except session.Unbound:
        check(True, "an unbound session read raises in strict mode")
    try:
        contextvars.Context().run(wire.current)
        check(False, "an unbound wire read raises in strict mode")
    except session.Unbound:
        check(True, "an unbound wire read raises in strict mode")
    del os.environ["TB_STRICT_SESSION"]

    print(f"\n{'FAIL' if failures else 'PASS'}: {len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


asyncio.run(main())
