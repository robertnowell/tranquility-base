"""Your voice cuts the manager off (hf-25).

Turns are handled one at a time, in order (hf-13), so a "stop" said while the
manager thought about the last turn waited behind it, and the answer was
spoken anyway. Now:

  thinking: a stop said while a turn waits on a model cuts that turn at once;
            its answer is never said, and the stop itself is still handled.
  acting:   a stop said once a send has begun lets the send finish (an act on
            the world is never left half done) and cuts only the talk after it.
  command:  anything else said meanwhile, even to the manager, waits its turn
            and cuts nothing.
  talk-over: an interruption said over the manager's voice cuts its turn; the
            same frame in the quiet (every turn start is one) cuts nothing.

In process, with the judgement and the handlers stubbed: this is the queue and
the cut, not the classifier.

    TB_HOSTED=1 uv run python drills/barge_in_drill.py
"""

import asyncio
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import session  # noqa: E402
import wire  # noqa: E402
from manager import JevClient, Manager  # noqa: E402
from turns import effect  # noqa: E402
from vocab import Intent  # noqa: E402

failures: list[str] = []


def check(ok: bool, what: str):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def manager(log: list):
    m = Manager(JevClient("drill-key-unused"))
    intents = {"stop": Intent.MUTE, "invite": Intent.INVITE_NEXT}

    async def judge(text):
        await asyncio.sleep(0.05)  # the classifier, quick
        return 1.0, intents.get(text.split()[0], Intent.CUSTOM), 50, {}

    async def interrupted():
        log.append(("interruption",))

    async def turn(text, frame, direction):
        log.append(("start", text))
        if text.startswith("ask"):
            await asyncio.sleep(1.5)  # waits on a model
            log.append(("said", text))
        elif text.startswith("send"):
            await asyncio.sleep(0.2)  # the span pick

            async def send():
                await asyncio.sleep(0.5)
                log.append(("sent", text))
            await effect(send())
            log.append(("said", "I've sent your message"))
        log.append(("done", text))

    m._judge = judge
    m._turn = turn
    m.broadcast_interruption = interrupted
    return m


async def run(m, script):
    worker = asyncio.create_task(m._turns.run())
    for at, text in script:
        await asyncio.sleep(at)
        m._enqueue(text, None, None)
    await asyncio.sleep(0.1)
    await m._turns.drained()
    await asyncio.sleep(0.8)  # a shielded send outlives the turn it was cut from
    worker.cancel()


async def main():
    session.bind()
    wire.bind()

    log: list = []
    m = manager(log)
    t0 = time.monotonic()
    await run(m, [(0, "ask what the build agent is doing"), (0.3, "stop")])
    print("  thinking:", log)
    check(("said", "ask what the build agent is doing") not in log, "thinking: the answer is never said")
    check(("start", "stop") in log, "thinking: the stop is still handled in its turn")
    check(("interruption",) in log, "thinking: whatever was playing is interrupted")
    check(time.monotonic() - t0 < 1.5, "thinking: cut well before the model would have answered")

    log = []
    m = manager(log)
    await run(m, [(0, "send that to it"), (0.35, "stop")])
    print("  acting:", log)
    check(("sent", "send that to it") in log, "acting: a send already begun finishes")
    check(("said", "I've sent your message") not in log, "acting: the talk after it is cut")

    log = []
    m = manager(log)
    await run(m, [(0, "ask how it went"), (0.3, "invite the next agent")])
    print("  command:", log)
    check(("said", "ask how it went") in log, "command: another command cuts nothing")
    check(log.index(("done", "ask how it went")) < log.index(("start", "invite the next agent")),
          "command: and it waits its turn")

    log = []
    m = manager(log)
    worker = asyncio.create_task(m._turns.run())
    m._enqueue("ask for a status", None, None)
    await asyncio.sleep(0.2)
    m._interrupted()  # a turn start in the quiet
    await asyncio.sleep(0.1)
    quiet_cut = ("done", "ask for a status") in log or m._turns._current is None
    session.current().bot_voice["speaking"] = True
    m._interrupted()  # the same, over the manager's voice
    await asyncio.sleep(0.1)
    session.current().bot_voice["speaking"] = False
    await m._turns.drained()
    worker.cancel()
    print("  talk-over:", log)
    check(not quiet_cut, "talk-over: an interruption frame in the quiet cuts nothing")
    check(("said", "ask for a status") not in log, "talk-over: said over its voice, the turn is cut")

    log = []
    m = manager(log)
    await run(m, [(0, "ask one"), (0.3, "stop"), (0.2, "ask two")])
    check(("said", "ask two") in log, "a cut never stops the turns behind it")

    print(f"\n{'FAIL' if failures else 'PASS'}: {len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    asyncio.run(main())
