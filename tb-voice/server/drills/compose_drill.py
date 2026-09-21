"""Drive the open message without a microphone: open, dictate in fragments,
hold, read-back after silence, yes, sent. Doors are stubbed; the manager's own
routing runs. `TB_READBACK_SECS=0.3 uv run python drills/compose_drill.py`."""

import asyncio
import os
import sys

os.environ.setdefault("TB_READBACK_SECS", "0.3")
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import manager  # noqa: E402


class FakeJev:
    last = {}

    async def compose(self, utterance, draft, dest):
        return {"choice": "content", "confidence": 0.5, "probabilities": {}}

    async def confirm(self, utterance, question):
        yes = utterance.lower().startswith(("yes", "yeah", "yep", "sure"))
        return {"choice": "yes" if yes else "other", "confidence": 1.0}

    async def target(self, utterance, live):
        return {"choice": live[0]["sessionId"], "confidence": 1.0, "probabilities": {}}


class FakeBrain:
    async def readback(self, text):
        return "investigate the logs and find why sends fail"

    async def compose_message(self, request, exchange):
        return ""


async def main():
    m = manager.Manager.__new__(manager.Manager)
    m._jev, m._brain = FakeJev(), FakeBrain()
    m.stage, m.pending, m.open, m._readback_task = None, None, None, None
    said, sent, cues = [], [], []

    async def say(text, voice="manager", session=None): said.append(text)
    async def send(sid, text): sent.append((sid, text))
    async def earcon(name): cues.append(name)
    async def targets(): return [{"sessionId": "abc12345", "name": "Planning", "project": "p"}]
    m._say, m._send, m._earcon, m._targets = say, send, earcon, targets
    manager.emit = _noop_emit
    enrolled = []

    async def run(*argv, timeout=45.0):  # the enrol door, recorded instead of executed
        enrolled.append(argv[1:])
        return 0, "enrolled"
    manager._run = run

    await m._open({"kind": "agent", "sessionId": "abc12345", "name": "Claude Code"},
                  line="Started Claude Code. What would you like to say?")
    assert m.open and said == ["Started Claude Code. What would you like to say?"] and cues == ["listening"]

    await m._compose_turn("Investigate our recent logs to figure out", None, None)
    await m._compose_turn("Investigate our recent logs to figure out why sends fail.", None, None)  # STT re-emit
    await m._compose_turn("The", None, None)
    await m._compose_turn("Start with the send path.", None, None)
    assert m.open.text == "Investigate our recent logs to figure out why sends fail. The Start with the send path.", m.open.text
    assert not sent and len(said) == 1, "nothing sent, nothing said while dictating"

    await asyncio.sleep(0.6)  # silence: one read-back
    assert said[-1] == "I heard: investigate the logs and find why sends fail. Send to Claude Code?", said
    assert m.open.asked and not sent

    await m._compose_turn("No.", None, None)  # hold
    await asyncio.sleep(0.6)
    assert said.count("I heard: investigate the logs and find why sends fail. Send to Claude Code?") == 1, "no second read-back"

    await m._compose_turn("And check the retry counter.", None, None)  # more content resets asked
    assert not m.open.asked
    await asyncio.sleep(0.6)
    assert m.open.asked and said.count("I heard: investigate the logs and find why sends fail. Send to Claude Code?") == 2

    await m._compose_turn("Yes.", None, None)  # the word
    assert sent == [("abc12345", "Investigate our recent logs to figure out why sends fail. The Start with the send path. And check the retry counter.")], sent
    assert m.open is None

    # the certain path: a phrase sends at once, no wait
    await m._open({"kind": "agent", "sessionId": "abc12345", "name": "Claude Code"})
    await m._compose_turn("Run the tests and report back.", None, None)
    await m._compose_turn("Message complete.", None, None)
    assert sent[-1] == ("abc12345", "Run the tests and report back.") and m.open is None

    # trailing phrase on a long turn
    await m._open({"kind": "agent", "sessionId": "abc12345", "name": "Claude Code"})
    await m._compose_turn("Look at the crash reports from Friday and that's it, send it.", None, None)
    assert sent[-1][1] == "Look at the crash reports from Friday", sent[-1]

    # cancel
    await m._open({"kind": "agent", "sessionId": "abc12345", "name": "Claude Code"})
    await m._compose_turn("Something something.", None, None)
    await m._compose_turn("Never mind.", None, None)
    assert m.open is None and said[-1] == "Dropped." and len(sent) == 3

    # retarget
    await m._open({"kind": "agent", "sessionId": "zzz", "name": "Wrong One"})
    await m._compose_turn("No, the other one.", None, None)
    assert m.open.name == "Planning" and said[-1] == "For Planning. Go ahead."
    await m._compose_turn("Hello there.", None, None)
    await m._compose_turn("Send it.", None, None)
    assert sent[-1] == ("abc12345", "Hello there.")
    assert all(a[0] == "enroll" for a in enrolled) and len(enrolled) == 6, enrolled
    print("compose drill: PASS", {"said": len(said), "sent": len(sent), "cues": cues, "enrolled": len(enrolled)})


async def _noop_emit(*a, **k):
    pass


if __name__ == "__main__":
    asyncio.run(main())
