"""Two sessions, one after the other, through ONE running bot: the second must
open knowing nothing the first heard.

This is the live form of isolation_drill.py. Pipecat Cloud keeps a warm process
and runs the next session in it; a bot started once with -t websocket does the
same, so two connections to it are two sessions through one process. Never
point this at the production agent (hf-2): its turns would land in a real
person's context, which is how the carried turns of 22 Sep got there.

    TB_HOSTED=1 <keys> uv run bot.py -t websocket --port 7871
    uv run python drills/warm_process_drill.py ws://localhost:7871/ws one.wav two.wav
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


async def one_session(url: str, wav: str) -> list[dict]:
    with wave.open(wav, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, "16 kHz mono PCM16"
        pcm = w.readframes(w.getnframes())
    lines: list[dict] = []
    async with websockets.connect(url, max_size=None) as ws:
        async def pump():
            step = 16000 * 2 // 50
            for i in range(0, len(pcm), step):
                await ws.send(pcm[i:i + step]); await asyncio.sleep(0.02)
            for _ in range(600):  # 12 s of silence so the turn ends and the bot answers
                await ws.send(bytes(step)); await asyncio.sleep(0.02)
        pumper = asyncio.create_task(pump())
        try:
            while not pumper.done():
                try:
                    msg = await asyncio.wait_for(ws.recv(), 1.0)
                except TimeoutError:
                    continue
                if isinstance(msg, (bytes, bytearray)):
                    continue
                obj = json.loads(msg)
                lines.append(obj)
                if obj.get("request") == "run":
                    sub = obj["argv"][1] if len(obj["argv"]) > 1 else ""
                    code, out = CANNED.get(sub, (0, ""))
                    await ws.send(json.dumps({"reply": obj["id"], "code": code, "out": out}))
        finally:
            pumper.cancel()
    return lines


async def main(url: str, first: str, second: str):
    a = await one_session(url, first)
    b = await one_session(url, second)
    fails = []

    def check(ok, what):
        print(("PASS " if ok else "FAIL ") + what)
        if not ok:
            fails.append(what)

    a_said = [l for l in a if l.get("event") == "said"]
    check(bool(a_said), f"first session sent `said` lines ({len(a_said)})")
    a_you = [l["text"] for l in a_said if l.get("who") == "you"]
    print("  first session heard:", a_you)
    b_jev = [l for l in b if l.get("event") == "jev"]
    check(bool(b_jev), "second session reached the gate")
    if b_jev:
        # Strictly empty: a session's first gate comes before anything it has
        # heard or said. Comparing against the first session's `said` lines
        # passed vacuously on code that emits none, while the carried turns
        # were right there (run against 26f6121, 22 Sep).
        before = b_jev[0]["state"].get("conversation_before", [])
        print("  second session's first gate saw before it:", [c["text"][:60] for c in before])
        check(before == [], "second session's first gate has nothing before it")
    b_said = [l for l in b if l.get("event") == "said"]
    check(bool(b_said) and b_said[0].get("n") == 1, "second session numbers its lines from 1")
    print(f"\n{'FAIL' if fails else 'PASS'}: {len(fails)} failure(s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    asyncio.run(main(*sys.argv[1:4]))
