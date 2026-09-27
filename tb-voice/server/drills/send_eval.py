"""Sends through the loop, beside the span picker they replace (hf-6 step 2).

Two readings of every case, RUNS times each:
  old   the span picker as it was on main at cf9124d (frozen below): one
        completion that points at lines or a quote, the target given.
  loop  Manager._act: the loop ends in one act, send, ask or wait, choosing
        the target itself when nobody is on stage.

Cases:
  real     the 12 labelled real sends (span_cases.json, the developer's own
           speech, outside git): request, the lines said before it, and what
           should have gone out: nothing, a run of lines, or a quote.
  written  cases for what the loop now decides that the picker never did:
           which agent, and when to ask. Invented text.

Scored, worst first:
  WRONG   something was sent that is not the message, or to the wrong agent
  MISSED  the message existed and nothing was sent (asking counts as missed
          unless the case says asking is right)
  OK      the right words to the right agent, or nothing when nothing was said

    GC_API_KEY=... uv run python drills/send_eval.py <span_cases.json> [runs]
"""

import asyncio
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import httpx  # noqa: E402

import session  # noqa: E402
import span  # noqa: E402
import wire  # noqa: E402
from manager import JevClient, Manager  # noqa: E402

MAIL = {"sessionId": "aaaa1111-0000-4000-8000-000000000001", "name": "Mailchimp sends",
        "goal": "We are fixing the stuck Mailchimp sends", "project": "email"}
LAND = {"sessionId": "bbbb2222-0000-4000-8000-000000000002", "name": "Landing page",
        "goal": "We are building the landing page", "project": "site"}

WRITTEN = [
    {"i": "w1", "stage": None, "agents": [MAIL, LAND], "request": "Send that to the Mailchimp agent.",
     "cands": [{"n": 1, "text": "The Mailchimp sends are stuck in draft."}],
     "expect": {"kind": "lines", "last": "The Mailchimp sends are stuck in draft.",
                "first_any": ["The Mailchimp sends are stuck in draft."], "to": MAIL["sessionId"]}},
    {"i": "w2", "stage": MAIL, "agents": [MAIL, LAND], "request": "Send that to the landing page agent.",
     "cands": [{"n": 1, "text": "The hero image needs a darker overlay."}],
     "expect": {"kind": "lines", "last": "The hero image needs a darker overlay.",
                "first_any": ["The hero image needs a darker overlay."], "to": LAND["sessionId"]}},
    {"i": "w3", "stage": None, "agents": [MAIL, LAND], "request": "Send that over.",
     "cands": [{"n": 1, "text": "Let's make it warmer."}],
     "expect": {"kind": "ask"}},
    {"i": "w4", "stage": MAIL, "agents": [MAIL, LAND], "request": "Tell it the thing we talked about.",
     "cands": [{"n": 1, "text": "Okay."}, {"n": 2, "text": "Hmm."}],
     "expect": {"kind": "none_or_ask"}},
    {"i": "w5", "stage": MAIL, "agents": [MAIL, LAND], "request": "Tell it yes, resend the drafts.",
     "cands": [{"n": 1, "text": "Coffee's cold."}],
     "expect": {"kind": "quote", "has": "resend the drafts", "to": MAIL["sessionId"]}},
]

OLD_SYSTEM = (
    "A developer speaking to a voice assistant has asked it to send a message to a coding agent. "
    "You decide WHICH of their own words are that message. You never write, fix or rephrase "
    "anything: you only point. Answer with exactly one JSON object and nothing else:\n"
    '{"lines": [FROM, TO]}  when the message is a contiguous run of the numbered lines they '
    "said earlier (use their numbers; leave out chatter that is not for the agent);\n"
    '{"quote": "..."}  when the message is inside the request itself, copied character for '
    "character from it (for 'tell it yes, go ahead' the quote is 'yes, go ahead');\n"
    '{"none": true}  when they have not said the message yet, or you cannot tell which words are it.\n'
    "A request that only says where or whether to send (\"send that to it\", \"to the same agent\", "
    "\"send it over\") is not itself the message: point at their earlier lines, or answer none.\n"
    "Examples:\n"
    "Lines [4] The deploy script skips the second agent. [5] Can you make it deploy both. "
    "Request: send that to the deploy agent -> {\"lines\": [4, 5]}\n"
    "Lines [9] Right. Request: tell it yes, merge it -> {\"quote\": \"yes, merge it\"}\n"
    "Lines [2] Coffee's cold again. Request: send a message to the build agent -> {\"none\": true}\n"
    "Lines [6] The export drops the footer. [7] Also the images are stale. "
    "Request: and to the same one -> {\"lines\": [6, 7]}")


async def old_pick(client, case, cands):
    numbered = "\n".join(f"[{c.n}] {c.text}" for c in cands) or "(none)"
    agent, goal = case.get("agent") or "the agent", case.get("goal")
    body = {"model": os.getenv("GC_MODEL", "minimax-m2.7"), "max_tokens": 400, "temperature": 0, "messages": [
        {"role": "system", "content": OLD_SYSTEM},
        {"role": "user", "content": (f"Agent: {agent}" + (f", working on: {goal}" if goal else "") + "\n"
                                     f"Request: {case['request']}\n"
                                     f"Their lines since the last message was sent (oldest first):\n{numbered}")}]}
    r = await client.post("/chat/completions", json=body, timeout=20)
    r.raise_for_status()
    pick = span.check(span.parse_answer(r.json()["choices"][0]["message"].get("content") or ""), cands,
                      case["request"])
    return ("send", span.text_of(pick, cands), None) if pick else ("wait", None, None)


async def loop_act(case, cands):
    m = Manager(JevClient("eval-key-unused"))
    stage = case.get("stage") if "stage" in case else {"sessionId": "cccc3333-0000-4000-8000-000000000003",
                                                       "name": case.get("agent"), "goal": case.get("goal")}
    agents = case.get("agents") or [stage]
    m.stage = stage
    got = {}

    async def targets():
        return list(agents)

    async def waiting():
        return []

    async def brief(sid):
        return next(({"goal": a.get("goal"), "name": a.get("name")} for a in agents if a["sessionId"] == sid), None)

    async def cands_now():
        return cands

    async def send(sid, text, quiet=False):
        got.update(act="send", to=sid, text=text)

    async def say(text, **k):
        got.setdefault("act", "ask")
        got.setdefault("said", text)

    async def nothing(*a, **k):
        return None

    async def notes(query="", since_minutes=None, until_minutes=None, limit=80, day=None):
        # The Mac's record, as it would answer: here, the lines of the case.
        words = {w for w in query.lower().split() if len(w) >= 3}
        rows = [c for c in cands if not words or any(w in c.text.lower() for w in words)]
        return {"notes": [{"id": f"n{c.n}", "source": "handsfree", "text": c.text} for c in rows],
                "matched": len(rows)}

    m._targets, m._waiting, m._brief, m._send, m._say = targets, waiting, brief, send, say
    m._notes = notes
    m._take_stage = lambda a: nothing()
    m._earcon = nothing
    span.candidates = cands_now
    await m._act(case["request"])
    return got.get("act", "wait"), got.get("text"), got.get("to")


def score(case, act, text, to, cands) -> str:
    e = case["expect"]
    if e["kind"] == "ask":
        return "OK" if act == "ask" else ("WRONG" if act == "send" else "MISSED")
    if e["kind"] == "none_or_ask":
        return "WRONG" if act == "send" else "OK"
    if e["kind"] == "none":
        return "WRONG" if act == "send" else "OK"
    if act != "send":
        return "MISSED"
    if e.get("to") and to and to != e["to"]:
        return "WRONG"
    if e["kind"] == "quote":
        return "OK" if e["has"] in (text or "") else "WRONG"
    return "OK" if (text or "").strip().endswith(e["last"].strip()) and any(
        (text or "").strip().startswith(f.strip()) for f in e["first_any"]) else "WRONG"


async def main(path, runs=3):
    session.bind()
    wire.bind()
    real = json.load(open(path))
    gc = httpx.AsyncClient(base_url=os.getenv("GC_BASE_URL", "https://api.generalcompute.com/v1"),
                           headers={"Authorization": f"Bearer {os.environ['GC_API_KEY']}"})
    totals = {k: {"OK": 0, "MISSED": 0, "WRONG": 0} for k in ("old", "loop")}
    ms = []
    for group, cases in (("real", real), ("written", WRITTEN)):
        for case in cases:
            cands = [span.Candidate(n=c["n"], text=c["text"]) for c in case["cands"]]
            line = []
            for r in range(runs):
                if group == "real":
                    try:
                        act, text, to = await old_pick(gc, case, cands)
                    except Exception:
                        act, text, to = "wait", None, None
                    v = score(case, act, text, to, cands)
                    totals["old"][v] += 1
                    line.append(f"old {v}")
                t0 = time.monotonic()
                try:
                    act, text, to = await loop_act(case, cands)
                except Exception as e:
                    act, text, to = "error", str(e)[:80], None
                ms.append(int((time.monotonic() - t0) * 1000))
                v = score(case, act, text, to, cands)
                totals["loop"][v] += 1
                line.append(f"loop {v}:{act}")
                if v != "OK":
                    line.append(f"  [{(text or '')[:60]!r} -> {(to or '')[:8]}]")
            print(f"{group:<8}{str(case['i']):<5}{case['request'][:48]:<50} " + " ".join(line), flush=True)
    ms.sort()
    for k, t in totals.items():
        print(f"{k:<5} OK {t['OK']:>3}  MISSED {t['MISSED']:>3}  WRONG {t['WRONG']:>3}")
    print(f"loop time: median {ms[len(ms) // 2]} ms, worst {ms[-1]} ms")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 3))
