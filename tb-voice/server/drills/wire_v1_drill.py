"""Wire v1 end to end: the manager reads through the Mac's tools, and an app
that says no hello still works over request:run (hf-3, hf-4).

This plays the Mac. With --hello it announces agents, waiting, brief and
transcript, answers `wire` calls from canned data, and puts one fact in the
agent's transcript that is in no brief: the migration uses the PURPLE table.
Then it asks, by voice, which table the migration uses. If the answer says
purple, the hosted manager read the agent's transcript, which before this it
could not do at all. Without --hello the same session must still run, all on
request:run.

    TB_HOSTED=1 <keys> uv run bot.py -t websocket --port 7876
    uv run python drills/wire_v1_drill.py ws://localhost:7876/ws next.wav ask.wav --hello
    uv run python drills/wire_v1_drill.py ws://localhost:7876/ws next.wav ask.wav
"""

import asyncio
import json
import sys
import wave

import websockets

SID = "abc12345-0000-4000-8000-000000000001"
TARGETS = [{"sessionId": SID, "name": "Planning", "project": "migrations", "goal": "move the orders table"}]
STATUS = {"waiting": [{"sessionId": SID, "eventId": 1, "heard": False}]}
BRIEF = {"sessionId": SID, "goal": "move the orders table", "recap": "Migration written, tests green.",
         "proposal": "Run it on staging.", "findings": "", "solution": "", "why": "",
         "lastAssistantMessage": "Migration written and tested; ready for staging.",
         "transcriptPath": "/Users/someone/.claude/projects/x/abc.jsonl"}
TRANSCRIPT = {"turns": [
    {"who": "user", "text": "Which table should the new orders live in?"},
    {"who": "assistant", "text": "I put them in the PURPLE table, because the blue one is read-only during the freeze."},
    {"who": "assistant", "text": "Migration written and tested; ready for staging."},
], "total_turns": 3}
TOOLS = {"agents": TARGETS, "waiting": STATUS, "brief": BRIEF, "transcript": TRANSCRIPT}
LEGACY = {"targets": json.dumps(TARGETS), "status": json.dumps(STATUS), "brief": json.dumps(BRIEF)}


def pcm(path):
    with wave.open(path, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
        return w.readframes(w.getnframes())


async def main(url, first, second, hello):
    calls, runs, lines = [], [], []
    async with websockets.connect(url, max_size=None) as ws:
        if hello:
            await ws.send(json.dumps({"wire": "hello", "protocol": 1, "app_version": "drill",
                                      "tools": [{"name": n, "version": 1} for n in TOOLS]}))

        async def speak(audio, silence_s):
            step = 16000 * 2 // 50
            for i in range(0, len(audio), step):
                await ws.send(audio[i:i + step]); await asyncio.sleep(0.02)
            for _ in range(int(silence_s * 50)):
                await ws.send(bytes(step)); await asyncio.sleep(0.02)

        async def pump():
            await asyncio.sleep(2)
            await speak(pcm(first), 12)
            await speak(pcm(second), 16)

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
                if obj.get("wire") == "call":
                    calls.append(obj["tool"])
                    data = TOOLS.get(obj["tool"])
                    reply = {"wire": "result", "id": obj["id"], "ok": data is not None}
                    reply["data" if data is not None else "error"] = data if data is not None else {"code": "unknown_tool"}
                    await ws.send(json.dumps(reply))
                elif obj.get("request") == "run":
                    sub = obj["argv"][1] if len(obj["argv"]) > 1 else obj["argv"][0]
                    runs.append(sub)
                    await ws.send(json.dumps({"reply": obj["id"], "code": 0, "out": LEGACY.get(sub, "")}))
                else:
                    lines.append(obj)
        finally:
            pumper.cancel()

    fails = []

    def check(ok, what):
        print(("PASS " if ok else "FAIL ") + what)
        if not ok:
            fails.append(what)

    spoken = " ".join(str(l.get("text") or "") for l in lines if l.get("event") == "speaking")
    print("  calls:", calls)
    print("  request:run:", runs)
    print("  spoken:", spoken[:400])
    if hello:
        check("agents" in calls or "waiting" in calls, "fleet reads went over wire v1")
        check("transcript" in calls, "the answer read the agent's transcript through the Mac")
        check(not any(r in ("targets", "status", "brief") for r in runs), "no read fell back to request:run")
        check("purple" in spoken.lower(), "the answer used a fact that is only in the transcript")
    else:
        check(not calls, "an app with no hello gets no wire calls")
        check(any(r in ("targets", "status") for r in runs), "the fleet reads still go over request:run")
        check(any(l.get("event") == "speaking" for l in lines), "the session still speaks")
    print(f"\n{'FAIL' if fails else 'PASS'}: {len(fails)} failure(s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    asyncio.run(main(args[0], args[1], args[2], "--hello" in sys.argv))
