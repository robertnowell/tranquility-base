"""Say something, then "send that": what reaches the agent is exactly what was
said (hf-8). And "send a message" with nothing said sends nothing.

Plays the Mac, including its ledger: every `said` line the bot emits is kept
as the app keeps it (numbered, typed), and the `ledger` tool is answered from
it, since the last action. Three utterances per scenario:

  sent:    "Tranquility, what's next?"  (puts an agent on stage)
           "The Mailchimp sends are stuck in draft."
           "Tranquility, send that to this agent."
    PASS when the one message typed into the agent is, word for word, the
    transcriber's own text for the Mailchimp line.

  nothing: "Tranquility, what's next?"
           "Tranquility, can you send a message to this agent?"
    PASS when nothing is typed into the agent.

    TB_HOSTED=1 <keys> uv run bot.py -t websocket --port 7879
    uv run python drills/span_drill.py ws://localhost:7879/ws next.wav mail.wav sendthat.wav sendmsg.wav
"""

import asyncio
import json
import sys
import wave

import websockets

SID = "abc12345-0000-4000-8000-000000000001"
TARGETS = [{"sessionId": SID, "name": "Mailchimp", "project": "email", "goal": "fix the stuck sends"}]
STATUS = {"waiting": [{"sessionId": SID, "eventId": 1, "heard": False}]}
BRIEF = {"sessionId": SID, "goal": "fix the stuck sends", "recap": "Looking at the send queue.",
         "proposal": "Check the draft states.", "lastAssistantMessage": "Looking at the send queue."}


def pcm(path):
    with wave.open(path, "rb") as w:
        return w.readframes(w.getnframes())


async def session(url, wavs):
    ledger, sends, lines = [], [], []
    async with websockets.connect(url, max_size=None) as ws:
        await ws.send(json.dumps({"wire": "hello", "protocol": 1, "app_version": "span-drill",
                                  "tools": [{"name": n, "version": 1} for n in ("agents", "waiting", "brief", "ledger")]}))

        async def speak(audio, silence_s):
            step = 16000 * 2 // 50
            for i in range(0, len(audio), step):
                await ws.send(audio[i:i + step]); await asyncio.sleep(0.02)
            for _ in range(int(silence_s * 50)):
                await ws.send(bytes(step)); await asyncio.sleep(0.02)

        async def pump():
            await asyncio.sleep(2)
            for w in wavs:
                await speak(pcm(w), 9)
            await speak(b"", 8)

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
                if obj.get("event") == "said":
                    ledger.append({"n": len(ledger) + 1, **{k: obj.get(k) for k in ("role", "kind", "text", "target")}})
                    lines.append(obj)
                elif obj.get("wire") == "call":
                    tool = obj["tool"]
                    if tool == "ledger":
                        last_action = max([r["n"] for r in ledger if r["kind"] == "action"], default=0)
                        data = [r for r in ledger if r["n"] > last_action]
                    else:
                        data = {"agents": TARGETS, "waiting": STATUS, "brief": BRIEF}.get(tool)
                    await ws.send(json.dumps({"wire": "result", "id": obj["id"], "ok": True, "data": data}))
                elif obj.get("request") == "run":
                    argv = obj["argv"]
                    if len(argv) > 2 and argv[:2] == ["tbase", "send"]:
                        sends.append(argv[3] if len(argv) > 3 else "")
                    await ws.send(json.dumps({"reply": obj["id"], "code": 0, "out": ""}))
        finally:
            pumper.cancel()
    return ledger, sends


async def main(url, nxt, mail, sendthat, sendmsg):
    fails = []

    def check(ok, what):
        print(("PASS " if ok else "FAIL ") + what)
        if not ok:
            fails.append(what)

    ledger, sends = await session(url, [nxt, mail, sendthat])
    said_mail = [r["text"] for r in ledger if r["role"] == "user" and "Mailchimp" in (r["text"] or "")]
    print("  heard:", [(r["role"], r["kind"], r["text"]) for r in ledger if r["role"] == "user"])
    print("  typed into the agent:", sends)
    check(len(sends) == 1, "exactly one message was sent")
    check(bool(said_mail) and sends[:1] == said_mail[:1], "it is the transcriber's own words for the line, verbatim")

    ledger, sends = await session(url, [nxt, sendmsg])
    print("  typed into the agent:", sends)
    check(sends == [], "'send a message' with nothing said sends nothing")

    print(f"\n{'FAIL' if fails else 'PASS'}: {len(fails)} failure(s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    asyncio.run(main(*sys.argv[1:6]))
