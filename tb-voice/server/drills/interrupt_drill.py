"""Talking over the manager has to reach it.

22 Sep: interrupting did not work at all, and could not: while the manager
speaks, the echo gate feeds the transcriber silence, so nothing said then is
ever transcribed. A client that cancels its own echo says so in the session
body (`aec`), the gate stays open, and words spoken over the manager arrive.

This drill does not test the canceller, which is Apple's and needs no test. It
tests the wiring: with `aec` set, does a turn spoken while the bot is talking
reach a verdict?

    TB_HOSTED=1 <keys> uv run bot.py -t websocket --port 7863
    uv run python drills/interrupt_drill.py ws://localhost:7863/ws ask.wav
"""

import asyncio
import json
import sys
import wave

import websockets

CANNED = {
    "targets": (0, json.dumps([{"sessionId": "abc12345", "name": "Planning", "project": "p", "goal": "plan"}])),
    "status": (0, json.dumps({"waiting": []})),
}


def pcm(path: str) -> bytes:
    with wave.open(path, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1
        return w.readframes(w.getnframes())


async def main(url: str, wav: str, token: str | None = None):
    audio = pcm(wav)
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    events: list[str] = []
    spoke_at: list[float] = []
    loop = asyncio.get_running_loop()

    async with websockets.connect(url, additional_headers=headers, max_size=None) as ws:
        async def receive():
            async for message in ws:
                if isinstance(message, bytes):
                    continue
                obj = json.loads(message)
                if obj.get("request") == "run":
                    name = obj["argv"][1] if len(obj["argv"]) > 1 else ""
                    code, out = CANNED.get(name, (0, "{}"))
                    await ws.send(json.dumps({"reply": obj["id"], "code": code, "out": out}))
                    continue
                event = obj.get("event")
                if not event:
                    continue
                events.append(event)
                if event == "speaking":
                    spoke_at.append(loop.time())
                print(f"  {event} {(obj.get('text') or obj.get('intent') or '')[:60]}")

        reader = asyncio.create_task(receive())
        step = 640

        async def say(data: bytes, tail: int = 100):
            for i in range(0, len(data), step):
                await ws.send(data[i:i + step])
                await asyncio.sleep(0.02)
            for _ in range(tail):
                await ws.send(bytes(step))
                await asyncio.sleep(0.02)

        await asyncio.sleep(1.0)
        print("asking, so the manager starts talking")
        await say(audio)
        for _ in range(200):                       # wait for its voice to start
            if spoke_at:
                break
            await asyncio.sleep(0.1)
        if not spoke_at:
            print("FAIL: the manager never spoke, so there was nothing to interrupt")
            sys.exit(1)
        before = len([e for e in events if e in ("addressed", "listening")])
        print("speaking over it")
        await say(audio, tail=150)
        after = len([e for e in events if e in ("addressed", "listening")])
        reader.cancel()

    print(f"verdicts before the interruption: {before}, after: {after}")
    if after > before:
        print("interrupt drill: PASS (words spoken over the manager reached it)")
        sys.exit(0)
    print("interrupt drill: FAIL (nothing said over the manager was ever heard)")
    sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None))
