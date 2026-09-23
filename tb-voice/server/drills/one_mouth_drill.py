"""One mouth, and it still sounds like the right agent.

23 Sep: the app read session announcements aloud through its own speakers, on a
path the connection's canceller knows nothing about, and the manager
transcribed three of them back as the developer's speech and acted on them.

The line is now spoken down the connection like everything else — but in the
session's OWN ElevenLabs voice, or every agent would suddenly sound like the
manager. This holds the three things that can go wrong: the wrong voice, a
voice that never goes back, and a reconnect for a voice we are already using.
"""
import asyncio, sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import manager as M
import session


class FakeTTS:
    """The socket bakes the voice into its URL, so a change costs a reconnect.
    This counts them: a needless one is a stutter before every line."""
    class Settings:
        def __init__(self, voice=None): self.voice = voice

    def __init__(self, voice):
        self._settings = FakeTTS.Settings(voice)
        self.spoke_as = []
        self.reconnects = 0

    async def use_voice(self, voice_id):
        if not voice_id or voice_id == self._settings.voice:
            return
        self._settings.voice = voice_id
        self.reconnects += 1


MANAGER_VOICE = "SAz9YHcvj6GT2YYXdXww"
RIVER, KAREN = "cjVigY5qzO86Huf0OWal", "pMsXgVXv3BLzUgSXRplE"
VOICES = {"aaaa1111": RIVER, "bbbb2222": KAREN}


async def main() -> int:
    session.bind()
    tts = FakeTTS(MANAGER_VOICE)
    m = M.Manager.__new__(M.Manager)          # no pipeline, no network
    m._tts, m._manager_voice = tts, None
    m._voice = asyncio.Lock()
    m._bot_stopped = asyncio.Event()
    m._bot_stopped.set()
    said = []

    async def push_frame(frame, direction=None): pass
    async def emit(*a, **k): pass
    m.push_frame = push_frame
    M.emit = emit
    M._run = lambda *a, **k: asyncio.sleep(0, result=(0, ""))

    async def say(text, voice="manager", session=None, voice_id=None):
        await M.Manager._say(m, text, voice, session, voice_id)
        said.append((text, tts._settings.voice))
    m._voice_for = lambda sid: asyncio.sleep(0, result=VOICES.get(sid))

    fails = []
    def check(what, got, want):
        print(f"   {'ok  ' if got == want else 'FAIL'}  {what}: {got!r}" + ("" if got == want else f" wanted {want!r}"))
        if got != want: fails.append(what)

    await say("Listening.")
    check("the manager speaks as the manager", tts._settings.voice, MANAGER_VOICE)

    await say("Planning is waiting on you.", voice="agent", session="aaaa1111", voice_id=RIVER)
    check("a session speaks in its own voice", tts._settings.voice, RIVER)

    await say("I've sent your message.")
    check("and the manager gets its voice back", tts._settings.voice, MANAGER_VOICE)

    before = tts.reconnects
    await say("Still the manager.")
    check("no reconnect for a voice already in use", tts.reconnects, before)

    await say("Mirai has a question.", voice="agent", session="bbbb2222", voice_id=KAREN)
    check("a second session gets its own voice", tts._settings.voice, KAREN)
    await say("Anything else?")
    check("back to the manager again", tts._settings.voice, MANAGER_VOICE)

    check("one reconnect per change of speaker, and no more", tts.reconnects, 4)

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
