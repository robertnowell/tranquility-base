"""Logging off the hot path, and the record reaches the Mac (hf-14).

Hosted, every model call went to calls.jsonl inside a container many
developers' sessions share, and the gate verdicts to its bot.log, so the
viewer's calls and gate columns never moved for a hosted session. Now a call
record is queued on its own session's logbox and sent to that Mac in parts,
behind every line the panel is waiting for. Checks, in process:

  queued      record() writes nothing in the container; it queues
  isolated    each session's records reach only its own queue; none without one
  parts       a 40 KB record goes as parts under 16 KB that join back exactly
  behind      a part waits while the outbox has a line for the panel
  viewer      tail.py joins the parts into the calls column and turns a
              verdict into the gate column's line, with its whole text

    uv run python drills/log_drill.py
"""

import asyncio
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import calls  # noqa: E402
import session  # noqa: E402
import wire  # noqa: E402

failures: list[str] = []


def check(ok: bool, what: str):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


async def one(name: str) -> list:
    session.bind()
    w = wire.bind()
    calls.record("jev", {"who": name}, {"ok": True}, ms=5)
    await asyncio.sleep(0)
    got = []
    while not w.logbox.empty():
        got.append(w.logbox.get_nowait())
    return got


async def main():
    here = os.path.join(os.path.dirname(calls.__file__), "calls.jsonl")
    size = os.path.getsize(here) if os.path.exists(here) else -1
    a, b = await asyncio.gather(asyncio.create_task(one("a")), asyncio.create_task(one("b")))
    after = os.path.getsize(here) if os.path.exists(here) else -1
    check(size == after, "queued: nothing written to calls.jsonl in the container")
    check([r["request"]["who"] for r in a] == ["a"] and [r["request"]["who"] for r in b] == ["b"],
          "isolated: each session's record reached only its own queue")
    orphan = await asyncio.create_task(asyncio.to_thread(lambda: calls.record("jev", {}, {})))
    check(orphan["kind"] == "jev", "isolated: a record with no session is dropped, not sent anywhere")

    big = {"t": 1.0, "kind": "loop", "ms": 900, "request": {"messages": [{"role": "user", "content": "é" * 20000}]},
           "response": {"choices": [{"message": {"content": "x" * 20000}}]}}
    ps = calls.parts(big, "id1")
    sizes = [len(json.dumps(p).encode()) for p in ps]
    check(len(ps) > 1 and max(sizes) < 16 * 1024, f"parts: {len(ps)} parts, largest {max(sizes)} bytes")
    check(json.loads("".join(p["text"] for p in ps)) == big, "parts: joined back, the record is exact")

    from manager import JevClient, Manager
    session.bind()
    w = wire.bind()
    m = Manager(JevClient("drill-key-unused"))
    sent = []

    async def push(frame, *a, **k):
        sent.append(frame.message)
    m.push_frame = push
    w.outbox.put_nowait({"event": "speaking", "text": "for the panel"})
    calls.record("jev", {"q": 1}, {"a": 1})
    task = asyncio.create_task(m._drain_log())
    await asyncio.sleep(0.2)
    held = list(sent)
    w.outbox.get_nowait()
    await asyncio.sleep(0.2)
    task.cancel()
    check(not held and sent and sent[0]["event"] == "call", "behind: the record waited for the panel's line, then went")

    import tail
    out = []

    class H(tail.Handler):
        def __init__(self):
            pass

        def _send(self, kind, data):
            out.append((kind, data))
    h, acc = H(), {}
    for p in reversed(ps):  # any order
        h._event(json.dumps(p), acc)
    joined = [d for k, d in out if k == "call"]
    check(len(joined) == 1 and json.loads(joined[0]) == big, "viewer: the parts join into one call in the calls column")
    long = "send what I said about the landing page " * 8
    h._event(json.dumps({"event": "addressed", "t": 1790000000.5, "p": 0.91, "intent": "send_message",
                         "ms": 210, "text": long}), acc)
    gate = [json.loads(d) for k, d in out if k == "log"]
    check(gate and gate[-1]["line"].endswith(long) and "SPEAK" in gate[-1]["line"],
          "viewer: a verdict becomes the gate column's line, with its whole text")
    check([k for k, _ in out][-1] == "event", "viewer: the verdict still shows in the events column")

    print(f"\n{'FAIL' if failures else 'PASS'}: {len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    asyncio.run(main())
