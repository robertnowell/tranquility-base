"""An invitation that was announced finishes, even if the turn is cut.

27 Sep 01:39, from the app's own log:

    01:39:00.691  stage
    01:39:00.692  speaking  "Inviting Tranquility base architecture review to speak."
    01:39:02.385  hearing              <- a breath, as the manager's voice ended
    01:39:02.387  quiet
    (nothing, ever)

The stage was taken and the promise was made; then a turn started, the task
carrying the invitation was cancelled, and the agent never spoke. The panel sat
on "Inviting ... to speak" with no error anywhere, because a cancelled task is
not a failure. One word is enough to start a turn over the manager's voice, and
the end of its own sentence is exactly when a breath lands.

turns.py named this failure before it happened again: "an invite that died
between 'Inviting…' and the hear verb once left nobody speaking". Starting an
agent was shielded for it. Inviting one was not.

An interruption may stop the manager TALKING. It must not undo something the
manager has already said it is doing.
"""
import asyncio, sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import manager as M


async def main() -> int:
    fails = []

    def check(what, ok):
        print(f"   {'ok  ' if ok else 'FAIL'}  {what}")
        if not ok:
            fails.append(what)

    m = M.Manager.__new__(M.Manager)
    spoke: list[str] = []
    announced = asyncio.Event()

    async def next_session():
        return {"sessionId": "aaaa1111", "name": "Architecture review", "project": "p", "goal": "g"}

    async def say_and_wait(text):
        spoke.append(text)
        announced.set()
        await asyncio.sleep(0.05)       # the sentence is still playing

    async def brief(sid):
        await asyncio.sleep(0.05)       # the door call the cancellation used to land on
        return {"recap": "It is done.", "proposal": "Ship it?"}

    async def app_speaks(url, text, session_id=None):
        spoke.append(f"agent:{text}")

    m._next_session = next_session
    m._say_and_wait = say_and_wait
    m._say = lambda *a, **k: asyncio.sleep(0)
    m._brief = brief
    m._app_speaks = app_speaks
    M.emit = lambda *a, **k: asyncio.sleep(0)
    M.note = lambda *a, **k: None

    turn = asyncio.create_task(M.Manager._do_invite_next(m, "next", None, None))
    await announced.wait()
    # Cancelled DURING the announcement, which is when it really happened:
    # `hearing` fired while "Inviting ... to speak" was still playing.
    turn.cancel()
    try:
        await turn
    except asyncio.CancelledError:
        pass
    # Long enough for the whole act: the sentence, the breath the handler
    # takes after it, and the door call for the brief. The first version of
    # this drill waited 0.2 s, which is shorter than the act, and reported the
    # fix as broken.
    await asyncio.sleep(0.6)

    check("the manager announced the invitation", any(s.startswith("Inviting") for s in spoke))
    check("and the agent spoke anyway, after the turn was cancelled",
          any(s.startswith("agent:") for s in spoke))
    check("with the brief it was invited to give",
          any("It is done." in s for s in spoke))

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
