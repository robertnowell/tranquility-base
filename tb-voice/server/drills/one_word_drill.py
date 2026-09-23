"""One word has to be enough to cut the manager off.

23 Sep: "Stop." and "Actually," were each heard and each discarded, because a
turn needed two words while the bot was speaking, so the only way through was
to keep talking for three seconds. This drives the shortest possible
interruption: one word, over the top.
"""
import asyncio, json, sys, wave, websockets

CANNED = {"targets": (0, json.dumps([{"sessionId": "abc12345", "name": "Planning", "project": "p", "goal": "plan"}])),
          "status": (0, json.dumps({"waiting": []}))}

def pcm(path):
    with wave.open(path, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1
        return w.readframes(w.getnframes())

async def main(url, ask_wav, one_word_wav):
    ask, word = pcm(ask_wav), pcm(one_word_wav)
    events, spoke = [], []
    loop = asyncio.get_running_loop()
    async with websockets.connect(url, max_size=None) as ws:
        async def receive():
            async for m in ws:
                if isinstance(m, bytes):
                    continue
                o = json.loads(m)
                if o.get("request") == "run":
                    name = o["argv"][1] if len(o["argv"]) > 1 else ""
                    code, out = CANNED.get(name, (0, "{}"))
                    await ws.send(json.dumps({"reply": o["id"], "code": code, "out": out}))
                    continue
                if e := o.get("event"):
                    events.append(e)
                    if e == "speaking":
                        spoke.append(loop.time())
                    print(f"  {e} {(o.get('text') or o.get('intent') or '')[:50]}")
        reader = asyncio.create_task(receive())

        async def say(data, tail=80):
            for i in range(0, len(data), 640):
                await ws.send(data[i:i + 640]); await asyncio.sleep(0.02)
            for _ in range(tail):
                await ws.send(bytes(640)); await asyncio.sleep(0.02)

        await asyncio.sleep(1.0)
        await say(ask)
        for _ in range(200):
            if spoke: break
            await asyncio.sleep(0.1)
        if not spoke:
            print("FAIL: nothing to interrupt"); sys.exit(1)
        before = len([e for e in events if e in ("addressed", "listening")])
        at = loop.time()
        print("saying one word over it")
        await say(word, tail=120)
        # Wait for the verdict rather than a fixed window: the turn has to end
        # before it is judged, and the stop strategy is deliberately patient.
        for _ in range(200):
            if len([e for e in events if e in ("addressed", "listening")]) > before:
                break
            await asyncio.sleep(0.1)
        after = len([e for e in events if e in ("addressed", "listening")])
        reader.cancel()
    print(f"verdicts before {before}, after {after}")
    print("one word drill:", "PASS" if after > before else "FAIL")
    sys.exit(0 if after > before else 1)

asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3]))
