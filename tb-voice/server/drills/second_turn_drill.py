"""A second turn after the bot has spoken must be heard.

22 Sep, 19:59: the manager answered one question, then went deaf. The mic kept
sending (rms 0.03 at the app), the bot's VAD saw three more turns start and
stop, and the transcriber produced not one word for any of them: no verdict, no
line, the panel frozen on the last answer. Every drill until now spoke once per
session, so nothing caught it.

    TB_HOSTED=1 <keys> uv run bot.py -t websocket --port 7863
    uv run python drills/second_turn_drill.py ws://localhost:7863/ws ask.wav
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
        assert w.getframerate() == 16000 and w.getnchannels() == 1, "16 kHz mono please"
        return w.readframes(w.getnframes())


async def speak(ws, audio: bytes):
    """The WAV at real time, then silence so the turn ends."""
    step = 640
    for i in range(0, len(audio), step):
        await ws.send(audio[i:i + step])
        await asyncio.sleep(0.02)
    for _ in range(100):  # 2 s of room
        await ws.send(bytes(step))
        await asyncio.sleep(0.02)


async def main(url: str, wav: str, token: str | None = None):
    audio = pcm(wav)
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    turns: list[list[str]] = [[], []]
    turn = 0
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
                if event:
                    turns[turn].append(event)
                    print(f"  turn {turn + 1}: {event} {(obj.get('text') or obj.get('intent') or '')[:60]}")

        reader = asyncio.create_task(receive())
        await asyncio.sleep(1.0)  # the pipeline says ready
        for turn in range(2):
            print(f"turn {turn + 1}: speaking")
            await speak(ws, audio)
            # Wait for the answer to finish: speaking, then quiet.
            for _ in range(200):
                if "quiet" in turns[turn]:
                    break
                await asyncio.sleep(0.1)
            await asyncio.sleep(1.5)  # a beat, as a person would leave
        reader.cancel()

    ok = True
    for i, events in enumerate(turns):
        heard = "addressed" in events or "listening" in events
        answered = events.count("speaking")
        print(f"turn {i + 1}: {events}")
        if not heard:
            print(f"FAIL: turn {i + 1} was never transcribed or judged")
            ok = False
        # One sentence, one answer. A transcriber that ends a final after the
        # vocative used to buy two (13:09, 22 Sep).
        if answered > 1:
            print(f"FAIL: turn {i + 1} was answered {answered} times for one sentence")
            ok = False
    print("second turn drill:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None))
