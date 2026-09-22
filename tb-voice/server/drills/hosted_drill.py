"""Speak to a hosted bot over its WebSocket the way the app will: stream a
16 kHz PCM16 WAV up, collect the JSON lines and the 24 kHz audio down, answer
the bot's door requests with canned replies. Run the bot first:

    TB_HOSTED=1 <keys in env> uv run bot.py -t websocket --port 7862

then:  uv run python drills/hosted_drill.py ws://localhost:7862/ws ask.wav
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


async def main(url: str, wav: str, token: str | None = None):
    with wave.open(wav, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, "16 kHz mono PCM16"
        pcm = w.readframes(w.getnframes())
    lines, audio = [], bytearray()
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    async with websockets.connect(url, max_size=None, additional_headers=headers) as ws:
        async def pump():
            # 20 ms chunks in real time, then 15 s of silence so the turn ends and the bot answers
            step = 16000 * 2 // 50
            for i in range(0, len(pcm), step):
                await ws.send(pcm[i:i + step]); await asyncio.sleep(0.02)
            for _ in range(750):
                await ws.send(bytes(step)); await asyncio.sleep(0.02)
        pumper = asyncio.create_task(pump())
        try:
            while not pumper.done():
                try:
                    msg = await asyncio.wait_for(ws.recv(), 1.0)
                except asyncio.TimeoutError:
                    continue
                if isinstance(msg, (bytes, bytearray)):
                    audio.extend(msg); continue
                obj = json.loads(msg); lines.append(obj)
                if obj.get("request") == "run":
                    sub = obj["argv"][1] if len(obj["argv"]) > 1 else ""
                    code, out = CANNED.get(sub, (0, ""))
                    await ws.send(json.dumps({"reply": obj["id"], "code": code, "out": out}))
                    print("answered", obj["argv"][:3])
                else:
                    print(obj.get("event"), (obj.get("text") or obj.get("intent") or obj.get("name") or "")[:90])
        finally:
            pumper.cancel()
    events = [l.get("event") for l in lines]
    print("events:", events)
    print("audio down:", len(audio) // 2 // 24000, "s at 24 kHz")
    assert "ready" in events and "hearing" in events, events
    assert "addressed" in events, "the name should have opened the gate"
    assert any(l.get("event") == "speaking" and l.get("voice") == "manager" for l in lines), "the manager should have spoken"
    assert len(audio) > 24000 * 2, "and its voice should have come down the wire"
    print("hosted drill: PASS")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None))
