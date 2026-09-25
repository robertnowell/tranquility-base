"""The loop against a frozen answer key (hf-6).

loop_eval.py prints answers for a person to judge. This scores them: a frozen
set of questions, each with a reference answer and the passage it comes from,
written from a frozen snapshot of this Mac's agents by someone who never saw
the loop's prompt. Every run reads the same record.

  questions.json  [{id, kind, stage, question, reference, must_include, evidence}]
                  kinds: recent, early (only far back in the session), across
                  (the fleet), not_in_record, open_decision
  snapshot/       targets.json, status.json, briefs/<id>.json,
                  transcripts/<id>.jsonl (text turns only)

Two readings per question, RUNS times each:
  old   main as of 733e020 for a question about the agent on stage: one
        completion over its brief and the last 7000 characters of its
        transcript. Not asked for `across`: that went to a different path,
        Pipecat's LLM, which is gone and is not replayed.
  loop  Manager._answer, its tools served from the snapshot.

A judge from another model family (OpenAI, JUDGE_MODEL) grades each answer
against the reference and its passage: right, partial, unknown (says the
record does not say, or it cannot tell) or wrong; and whether a wrong answer
was said with confidence. For not_in_record, "unknown" is the right answer.
For open_decision, right means it says the decision is still the developer's.

The set is split in two by a hash of each id, even across kinds. Prompt work
may look at `tune` only; `held` is the score.

    GC_API_KEY=... OPENAI_API_KEY=... uv run python drills/loop_graded_eval.py \\
        <questions.json> <snapshot dir> [runs] [split: tune|held|all] [out.json]
"""

import asyncio
import hashlib
import json
import os
import sys
import time
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import httpx  # noqa: E402

import session  # noqa: E402
import wire  # noqa: E402
from manager import BRIEF_FIELDS, Brain, JevClient, Manager  # noqa: E402

JUDGE_MODEL = os.getenv("JUDGE_MODEL", "gpt-5.4")

OLD_SYSTEM = (
    "You are a coding-agent session answering its supervisor aloud, in first person "
    "plural ('we'). Answer ONLY from the facts given. One or two sentences, 30 words "
    "max, no lists, no markdown. If the facts do not say, say so in one sentence. "
    "Spoken, so never say an id, hash, path, URL, branch or file name; say 'the file', "
    "'the branch', 'the PR', 'PR five forty-seven'. You answer questions; you cannot perform "
    "actions and must never claim to (no 'opening', 'sending', 'doing it now').")

JUDGE = """You grade a voice assistant's answer to a developer's question about their coding agents.
You are given the question, the kind of question, a reference answer written from the record,
facts a correct answer must contain, and the passages the reference comes from.

Grades:
- right: answers the question correctly; agrees with the reference; contains the must-include facts
  (paraphrase is fine; extra true detail is fine).
- partial: correct as far as it goes but misses a must-include fact, or is vaguer than useful.
- unknown: says the record does not say, that it cannot tell, or could not read it.
- wrong: states something the reference or passages contradict, or answers a different question,
  or invents an answer.
Special kinds:
- not_in_record: the record does not contain the answer. "unknown" is the correct behaviour, grade it
  "right". Any substantive answer is "wrong".
- open_decision: the developer has not decided yet. "right" says it is still open / the developer's
  call (naming what it hangs on is good). Claiming it was decided, or deciding it, is "wrong".
confident_wrong: true only when the grade is wrong AND the answer is stated as fact, without hedging.

Answer with one JSON object: {"grade": "right|partial|unknown|wrong", "confident_wrong": true|false,
"reason": "one sentence"}"""


def split_of(qid: str) -> str:
    return "tune" if int(hashlib.sha256(qid.encode()).hexdigest(), 16) % 2 == 0 else "held"


class Snapshot:
    def __init__(self, root: str):
        def data(p):
            o = json.load(open(os.path.join(root, p)))
            return o.get("data", o) if isinstance(o, dict) and "data" in o else o
        self.root = root
        self.targets = data("targets.json")
        self.waiting = (data("status.json") or {}).get("waiting") or []

    def brief(self, sid: str) -> dict | None:
        p = os.path.join(self.root, "briefs", f"{sid}.json")
        if not os.path.exists(p):
            hits = [f for f in os.listdir(os.path.join(self.root, "briefs")) if f.startswith(sid)]
            if len(hits) != 1:
                return None
            p = os.path.join(self.root, "briefs", hits[0])
        return json.load(open(p))


def manager_on(snap: Snapshot) -> Manager:
    m = Manager(JevClient("eval-key-unused"))

    async def targets():
        return list(snap.targets)

    async def waiting():
        return list(snap.waiting)

    async def brief(sid):
        return snap.brief(sid)

    m._targets, m._waiting, m._brief = targets, waiting, brief
    return m


async def old_answer(client, question: str, brief: dict) -> str:
    facts = {k: brief.get(k) for k in BRIEF_FIELDS}
    tail = Brain.transcript_tail(brief.get("transcriptPath"))
    body = {"model": os.getenv("GC_MODEL", "minimax-m2.7"), "max_tokens": 400, "temperature": 0.3, "messages": [
        {"role": "system", "content": OLD_SYSTEM},
        {"role": "user", "content": f"Facts about this session:\n{json.dumps(facts, ensure_ascii=False)}\n\n"
                                    f"The end of the session's transcript:\n{tail}\n\n"
                                    f"The exchange so far (you = the supervisor):\n\n\nQuestion: {question}"}]}
    r = await client.post("/chat/completions", json=body, timeout=30)
    r.raise_for_status()
    return " ".join((r.json()["choices"][0]["message"].get("content") or "").split())


async def judge(client, q: dict, answer: str) -> dict:
    body = {"model": JUDGE_MODEL, "response_format": {"type": "json_object"}, "messages": [
        {"role": "system", "content": JUDGE},
        {"role": "user", "content": json.dumps({
            "kind": q["kind"], "question": q["question"], "reference": q["reference"],
            "must_include": q.get("must_include") or [], "passages": [e.get("quote") for e in q.get("evidence") or []],
            "answer": answer or "(no answer: said it could not find that in time)"}, ensure_ascii=False)}]}
    for attempt in range(3):
        try:
            r = await client.post("https://api.openai.com/v1/chat/completions", json=body, timeout=90)
            r.raise_for_status()
            return json.loads(r.json()["choices"][0]["message"]["content"])
        except (httpx.HTTPError, ValueError, KeyError) as e:
            if attempt == 2:
                return {"grade": "error", "confident_wrong": False, "reason": str(e)[:200]}
            await asyncio.sleep(2 + 3 * attempt)


async def main(questions_path, snap_dir, runs=3, which="all", out_path=None):
    session.bind()
    wire.bind()
    snap = Snapshot(snap_dir)
    qs = [q for q in json.load(open(questions_path)) if which == "all" or split_of(q["id"]) == which]
    gc = httpx.AsyncClient(base_url=os.getenv("GC_BASE_URL", "https://api.generalcompute.com/v1"),
                           headers={"Authorization": f"Bearer {os.environ['GC_API_KEY']}"})
    oa = httpx.AsyncClient(headers={"Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}"})
    # One question at a time: four at once ran into the provider's rate limit
    # and 73 of 120 loop runs ended in a 429 (25 Sep), which measures nothing.
    sem = asyncio.Semaphore(int(os.getenv("EVAL_PARALLEL", "1")))
    rows = []

    async def one(q, r):
        async with sem:
            m = manager_on(snap)
            b = snap.brief(q["stage"]) if q.get("stage") else None
            m.stage = ({"sessionId": b.get("sessionId") or q["stage"], "name": b.get("name"), "goal": b.get("goal"),
                        "project": b.get("project")} if b else None)
            out = {"id": q["id"], "kind": q["kind"], "split": split_of(q["id"]), "run": r, "question": q["question"]}
            t0 = time.monotonic()
            o = await m._answer(q["question"], as_stage=bool(b))
            out["loop"] = {"answer": o.answer, "ms": o.ms, "steps": o.steps, "stopped": o.stopped,
                           "tools": [c["tool"] + ("?" if c["args"].get("query") else "") for c in o.calls],
                           "words": len((o.answer or "").split())}
            if b:
                t0 = time.monotonic()
                try:
                    old = await old_answer(gc, q["question"], b)
                except Exception as e:
                    old = f"(failed: {e})"
                out["old"] = {"answer": old, "ms": int((time.monotonic() - t0) * 1000), "words": len(old.split())}
        for k in ("loop", "old"):
            if k in out:
                out[k]["grade"] = await judge(oa, q, out[k]["answer"])
        rows.append(out)
        g = out["loop"]["grade"]
        print(f"{q['id']} {q['kind']:<14} run {r} loop {g.get('grade'):<8}"
              + (f" old {out['old']['grade'].get('grade')}" if "old" in out else ""), flush=True)

    await asyncio.gather(*(one(q, r) for r in range(runs) for q in qs))

    def table(sel, label):
        print(f"\n== {label}: {len({x['id'] for x in sel})} questions x {runs}")
        print(f"{'':<16}{'reading':<7}{'right':>7}{'partial':>9}{'unknown':>9}{'wrong':>7}{'sure+wrong':>12}")
        by_kind = defaultdict(list)
        for x in sel:
            by_kind[x["kind"]].append(x)
        for kind in ["ALL"] + sorted(by_kind):
            xs = sel if kind == "ALL" else by_kind[kind]
            for k in ("loop", "old"):
                gs = [x[k]["grade"] for x in xs if k in x]
                if not gs:
                    continue
                c = Counter(g.get("grade") for g in gs)
                sure = sum(1 for g in gs if g.get("confident_wrong"))
                print(f"{kind:<16}{k:<7}{c['right']:>4}/{len(gs):<3}{c['partial']:>6}{c['unknown']:>9}{c['wrong']:>7}{sure:>10}")

    for sp in ("held", "tune"):
        sel = [x for x in rows if x["split"] == sp]
        if sel:
            table(sel, sp)
    ms = sorted(x["loop"]["ms"] for x in rows)
    words = sorted(x["loop"]["words"] for x in rows)
    print(f"\nloop time: median {ms[len(ms) // 2]} ms, 90th {ms[int(len(ms) * 0.9)]} ms, worst {ms[-1]} ms; "
          f"words: median {words[len(words) // 2]}, over 30: {sum(w > 30 for w in words)} of {len(words)}; "
          f"no answer: {sum(1 for x in rows if not x['loop']['answer'])}")
    if out_path:
        json.dump(sorted(rows, key=lambda x: (x["id"], x["run"])), open(out_path, "w"), indent=1)
        print(f"(rows: {out_path})")


if __name__ == "__main__":
    a = sys.argv
    asyncio.run(main(a[1], a[2], int(a[3]) if len(a) > 3 else 3, a[4] if len(a) > 4 else "all",
                     a[5] if len(a) > 5 else None))
