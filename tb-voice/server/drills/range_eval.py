"""Acting on a range of what was said (hf-18 follow-on, 27 Sep).

The manager can answer from, send, or hand to the Notes agent any stretch of
the developer's record (ManagerNotes on the Mac, `notes` over the wire). This
plays that record from invented lines spread over two days and checks:

  answer   a question about what was said is answered from it, and one about
           something never said is answered "the record does not say"
  send     "send what I said about X" sends X's lines, copied, and none of
           the others, to the agent named
  notes    handed to the Notes agent, the request goes on top and the lines
           follow as said
  narrow   a range past the cap (60 lines or 8,000 characters) is not sent:
           the manager asks to narrow it

    GC_API_KEY=... uv run python drills/range_eval.py [runs]
"""

import asyncio
import os
import sys
import time
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import session  # noqa: E402
import span  # noqa: E402
import wire  # noqa: E402
from manager import JevClient, Manager  # noqa: E402
import manager as _manager  # noqa: E402

_manager._now_line = lambda: NOW.strftime("%A %d %B %Y, %H:%M (UTC)")

# One fixed moment for the record AND for the time the manager is told
# (manager._now_line, patched below): against the real clock, "yesterday" and
# "today" meant different lines depending on the hour the eval ran.
NOW = datetime(2026, 9, 27, 15, 0, tzinfo=timezone.utc)
SITE = {"sessionId": "aaaa1111-0000-4000-8000-000000000001", "name": "Landing page",
        "goal": "We are building the landing page", "project": "site"}
MAIL = {"sessionId": "bbbb2222-0000-4000-8000-000000000002", "name": "Mailchimp sends",
        "goal": "We are fixing the stuck Mailchimp sends", "project": "email"}
NOTES_AGENT = {"sessionId": "cccc3333-0000-4000-8000-000000000003", "name": "Notes"}

# minutes ago, source, text (invented)
RECORD = [
    (1500, "handsfree", "Pricing should start at ten dollars a month for one seat."),
    (1490, "handsfree", "And teams get a discount past five seats."),
    (1480, "dictation", "Tell the landing agent to drop the mint colours, they read as cheap."),
    (1300, "handsfree", "The cat knocked the monitor over again."),
    (300, "handsfree", "The landing page hero should be darker."),
    (298, "handsfree", "And the landing page headline should say what it does in six words."),
    (295, "handsfree", "The hackathon demo needs a recorded backup in case the wifi fails."),
    (292, "handsfree", "For the hackathon, open with the voice demo, not the slides."),
    (250, "dictation", "Mailchimp drafts are stuck because the audience is missing."),
    (8, "handsfree", "The export still drops the footer."),
    (6, "handsfree", "And the images in the export are stale."),
] + [(700 - i, "handsfree", f"Filler thought number {i} about the day.") for i in range(70)]


def fake_notes(query="", since_minutes=None, until_minutes=None, limit=80, day=None):
    rows = []
    if day:  # a calendar day, in UTC here (the eval's zone)
        start = datetime.fromisoformat(day).replace(tzinfo=timezone.utc)
        since_minutes = int((NOW - start).total_seconds() // 60)
        until_minutes = max(0, int((NOW - start - timedelta(days=1)).total_seconds() // 60))
    for ago, src, text in RECORD:
        if since_minutes is not None and ago > since_minutes:
            continue
        if until_minutes is not None and ago < until_minutes:
            continue
        rows.append((ago, src, text))
    words = {w for w in query.lower().replace(",", " ").split() if len(w) >= 3}
    if words:
        rows = [r for r in rows if any(w in r[2].lower() for w in words)]
    rows.sort(key=lambda r: -r[0])
    return {"notes": [{"id": f"n{i}", "at": (NOW - timedelta(minutes=a)).isoformat(), "source": s, "text": t}
                      for i, (a, s, t) in enumerate(rows[-limit:])], "matched": len(rows)}


def manager(stage=None):
    m = Manager(JevClient(os.environ.get("JEV_API_KEY", "eval-key-unused")))
    m.stage = stage
    got = {}

    async def targets():
        return [SITE, MAIL]

    async def nothing(*a, **k):
        return None

    async def notes(query="", since_minutes=None, until_minutes=None, limit=80, day=None):
        return fake_notes(query, since_minutes, until_minutes, limit, day)

    async def brief(sid):
        return next(({"goal": a["goal"], "name": a["name"]} for a in (SITE, MAIL) if a["sessionId"] == sid), None)

    async def send(sid, text, quiet=False):
        got.update(act="send", to=sid, text=text)

    async def say(text, **k):
        got.setdefault("act", "say")
        got.setdefault("said", text)

    async def cands(request=""):
        return []

    m._targets, m._brief, m._notes, m._send, m._say = targets, brief, notes, send, say
    m._waiting = lambda: nothing()
    m._take_stage = lambda a: nothing()
    m._earcon = nothing
    span.candidates = cands
    return m, got


def has(text, *words):
    t = (text or "").lower()
    return all(w.lower() in t for w in words)


async def answer_case(q, check):
    m, _ = manager()
    o = await m._answer(q)
    return ("OK" if check(o.answer) else "WRONG"), o.answer


async def act_case(q, stage, check):
    m, got = manager(stage)

    async def notes_session():
        return NOTES_AGENT

    m._notes_session = notes_session
    await m._act(q)
    return ("OK" if check(got) else "WRONG"), got


CASES = [
    ("answer", "What did I say about pricing yesterday?", None,
     lambda a: has(a, "ten dollar") or has(a, "$10") or has(a, "10 dollar")),
    ("answer", "Did I tell the landing agent to drop the mint colours?", None, lambda a: has(a, "mint")),
    ("answer", "What did I say about the database migration?", None,
     # "You haven't said anything about a database migration" is the right
     # answer and scored WRONG until 29 Sep, which is one in every five runs of
     # this case reported as a failure that never happened.
     lambda a: any(p in (a or "").lower() for p in ("does not say", "doesn't say", "didn't", "did not", "no record",
                                                     "nothing", "not mention", "never", "does not contain",
                                                     "doesn't contain", "does not show", "does not settle", "no mention",
                                                     "haven't said", "have not said", "hasn't said"))),
    ("send", "Send what I said about the landing page to the landing agent.", MAIL,
     lambda g: g.get("act") == "send" and g.get("to") == SITE["sessionId"] and has(g.get("text"), "hero")
     and not has(g.get("text"), "pricing") and not has(g.get("text"), "hackathon")),
    ("send", "Send the last ten minutes to it.", SITE,
     lambda g: g.get("act") == "send" and has(g.get("text"), "footer", "stale") and not has(g.get("text"), "hero")),
    ("notes", "Have the notes agent write up everything I said about the hackathon.", None,
     lambda g: g.get("act") == "send" and (g.get("text") or "").startswith("Have the notes agent")
     and has(g.get("text"), "backup", "voice demo")),
    ("narrow", "Send everything I said today to it.", SITE,
     lambda g: g.get("act") == "say" and "send" not in (g.get("act") or "")),
]


async def main(runs=5):
    session.bind()
    wire.bind()
    totals = {"OK": 0, "WRONG": 0}
    ms = []
    for kind, q, stage, check in CASES:
        marks = []
        for _ in range(runs):
            t0 = time.monotonic()
            try:
                if kind == "answer":
                    v, out = await answer_case(q, check)
                else:
                    v, out = await act_case(q, stage, check)
            except Exception as e:
                v, out = "WRONG", f"error {e}"
            ms.append(int((time.monotonic() - t0) * 1000))
            totals[v] += 1
            marks.append(v)
            if v != "OK":
                print(f"    {kind} miss: {str(out)[:220]}")
        print(f"{kind:<7}{q[:62]:<64}{' '.join(marks)}", flush=True)
    ms.sort()
    print(f"\nOK {totals['OK']}  WRONG {totals['WRONG']}  median {ms[len(ms) // 2]} ms, worst {ms[-1]} ms")


if __name__ == "__main__":
    asyncio.run(main(int(sys.argv[1]) if len(sys.argv) > 1 else 5))
