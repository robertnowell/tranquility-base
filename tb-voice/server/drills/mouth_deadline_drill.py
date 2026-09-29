"""The mouth is held until the speech stops, and the stop says what it stopped.

Two failures, both measured on this Mac's ledger over 22-29 Sep:

  * `_say` held the voice lock for a fixed 12 s. The manager's capabilities
    line is 328 characters and reached its stop in 18.0 s, so for six seconds
    the mouth was free while it was still talking and whatever was queued
    played over the top.
  * `quiet` named nothing, so a stop could not be paired with its start. 57 of
    210 utterances had no `quiet` inside twelve seconds and there was no way to
    tell an overrun from a lost frame from another utterance's stop.

    uv run python drills/mouth_deadline_drill.py
"""
import asyncio
import sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import manager as M
import session
from pipecat.processors.frame_processor import FrameDirection

fails = 0


def ok(claim, cond):
    global fails
    print(f"   {'ok   ' if cond else 'FAIL '} {claim}")
    fails += 0 if cond else 1


# -- the deadline, at the sizes the manager actually speaks ---------------------

ok("a short line waits no less than it used to", M._speech_deadline("Inviting Marker-one to speak.") == 12.0)
ok("the 222-character line outlasts its measured 14.4 s", M._speech_deadline("x" * 222) > 14.4)
ok("the 328-character line outlasts its measured 18.0 s", M._speech_deadline("x" * 328) > 18.0)
ok("and 18.0 s would have beaten the old deadline", 18.0 > 12.0)
ok("a runaway line is capped rather than held for ever", M._speech_deadline("x" * 100_000) == 90.0)


# -- the stop names the line it stopped -----------------------------------------

class FakeTTS:
    class Settings:
        def __init__(self): self.voice = "manager-voice"

    def __init__(self): self._settings = FakeTTS.Settings()

    async def use_voice(self, voice_id): pass


async def run():
    session.bind()
    events = []

    async def fake_emit(processor, event, **fields):
        events.append({"event": event, **fields})

    M.emit = fake_emit
    m = M.Manager(M.JevClient("drill-key-unused"))
    m._tts = FakeTTS()

    async def push_frame(frame, direction=None): pass
    m.push_frame = push_frame

    async def stops_after(secs):
        """The speech ending, through the manager's own frame handler -- not a
        copy of it, or the drill would pass with that handler broken."""
        await asyncio.sleep(secs)
        await m.process_frame(M.BotStoppedSpeakingFrame(), FrameDirection.DOWNSTREAM)

    # A line whose speech stops normally.
    asyncio.get_event_loop().create_task(stops_after(0.2))
    await m._say("Inviting Marker-one to speak.")
    start = next((e for e in events if e["event"] == "speaking"), None)
    stop = next((e for e in events if e["event"] == "quiet"), None)
    ok("the start carries an id and the length of the line", bool(start and start.get("id") and start.get("chars") == 29))
    ok("the stop carries the SAME id", bool(stop and start and stop.get("id") == start["id"]))
    # `took`, not `secs`: the app's `secs` is an Int, and a fraction decoded
    # into one fails the whole event -- a `quiet` nothing can read is a card
    # left half lit (29 Sep, an hour after this drill first passed).
    ok("and how long that line took", bool(stop and isinstance(stop.get("took"), float)))
    ok("under a name the app can decode", bool(stop and "secs" not in stop))
    ok("a stop that arrived in time is not marked over", stop is not None and "over" not in stop)

    # A line whose speech never reports stopping: the mouth is let go on the
    # deadline, and the record says that is what happened.
    events.clear()
    M._speech_deadline = lambda text: 0.3   # the real one is asserted above
    await m._say("A line nothing ever reports the end of.")
    ok("the mouth is released rather than held for ever", True)  # reaching here is the assertion
    over = m._utterance
    ok("the utterance is marked over when the deadline fired", bool(over and over.get("over")))
    m._bot_stopped.clear()
    await stops_after(0.0)
    late = next((e for e in events if e["event"] == "quiet"), None)
    ok("and its late stop says so", bool(late and late.get("over") is True))

asyncio.run(run())
print("FAIL" if fails else "PASS")
sys.exit(1 if fails else 0)
