"""Questions about real agents, answered the old way and by the loop (hf-6).

The old way (main as of 733e020, frozen below): one completion over the
agent's brief and the last 7000 characters of its transcript, fetched in
advance; with nobody on stage, Pipecat's tool-calling LLM, which is not
replayed here. The loop: the model reads what it decides to (loop.py).

Each case is a question the developer asked, or would, about an agent that
still has a brief and a transcript on this Mac. Both answers are printed with
the loop's steps, tools and time, and written to a JSON file for judging.
Judged by reading them against the record: is the answer true, is it from
the record (not generic), and does it answer the question.

Runs locally against this Mac's tbase (TBASE_BIN), never a cloud agent:

    TBASE_BIN=... GC_API_KEY=... uv run python drills/loop_eval.py <cases.json> [runs] [out.json]

cases.json: [{"q": "...", "stage": "<session id>" | null}, ...]
"""

import asyncio
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import httpx  # noqa: E402

import session  # noqa: E402
import wire  # noqa: E402
from manager import BRIEF_FIELDS, Brain, JevClient, Manager  # noqa: E402

OLD_SYSTEM = (
    "You are a coding-agent session answering its supervisor aloud, in first person "
    "plural ('we'). Answer ONLY from the facts given. One or two sentences, 30 words "
    "max, no lists, no markdown. If the facts do not say, say so in one sentence. "
    "Spoken, so never say an id, hash, path, URL, branch or file name; say 'the file', "
    "'the branch', 'the PR', 'PR five forty-seven'. You answer questions; you cannot perform "
    "actions and must never claim to (no 'opening', 'sending', 'doing it now').")


async def old_answer(client: httpx.AsyncClient, question: str, brief: dict) -> tuple[str, int]:
    facts = {k: brief.get(k) for k in BRIEF_FIELDS}
    tail = Brain.transcript_tail(brief.get("transcriptPath"))
    body = {"model": os.getenv("GC_MODEL", "minimax-m2.7"), "max_tokens": 400, "temperature": 0.3, "messages": [
        {"role": "system", "content": OLD_SYSTEM},
        {"role": "user", "content": f"Facts about this session:\n{json.dumps(facts, ensure_ascii=False)}\n\n"
                                    f"The end of the session's transcript:\n{tail}\n\n"
                                    f"The exchange so far (you = the supervisor):\n\n\nQuestion: {question}"}]}
    t0 = time.monotonic()
    r = await client.post("/chat/completions", json=body, timeout=20)
    r.raise_for_status()
    text = r.json()["choices"][0]["message"].get("content") or ""
    return " ".join(text.split()), int((time.monotonic() - t0) * 1000)


async def main(cases_path, runs=1, out_path=None):
    session.bind()
    wire.bind()
    cases = json.load(open(cases_path))
    m = Manager(JevClient("eval-key-unused"))
    client = httpx.AsyncClient(base_url=os.getenv("GC_BASE_URL", "https://api.generalcompute.com/v1"),
                               headers={"Authorization": f"Bearer {os.environ['GC_API_KEY']}"})
    targets = {t["sessionId"]: t for t in await m._targets()}
    results = []
    for case in cases:
        for r in range(runs):
            sid = case.get("stage")
            m.stage = None
            if sid:
                b = await m._brief(sid) or {}
                m.stage = {"sessionId": sid, "name": (targets.get(sid) or {}).get("name") or b.get("name"),
                           "goal": b.get("goal"), "project": b.get("project")}
            row = {"q": case["q"], "stage": m.stage and (m.stage.get("name") or m.stage.get("goal") or sid[:8]),
                   "run": r}
            if sid:
                try:
                    row["old"], row["old_ms"] = await old_answer(client, case["q"], await m._brief(sid) or {})
                except Exception as e:
                    row["old"], row["old_ms"] = f"(failed: {e})", 0
            o = await m._answer(case["q"], as_stage=bool(sid))
            row.update({"loop": o.answer, "loop_ms": o.ms, "steps": o.steps, "stopped": o.stopped,
                        "calls": [f"{c['tool']}({','.join(f'{k}={str(v)[:8]}' for k, v in c['args'].items())})"
                                  for c in o.calls]})
            results.append(row)
            print(f"\n## {row['q']}  [{row['stage'] or 'nobody on stage'}] run {r}")
            if sid:
                print(f"  old  ({row['old_ms']} ms): {row['old']}")
            print(f"  loop ({o.ms} ms, {o.steps} steps, {' '.join(row['calls']) or 'no tools'}"
                  f"{', stopped ' + o.stopped if o.stopped else ''}): {o.answer}")
    words = sorted(len((r["loop"] or "").split()) for r in results)
    print(f"\nloop answer length: median {words[len(words) // 2]} words, longest {words[-1]}; "
          f"over 30: {sum(w > 30 for w in words)} of {len(words)}")
    ms = sorted(r["loop_ms"] for r in results)
    print(f"\nloop time: median {ms[len(ms) // 2]} ms, worst {ms[-1]} ms; "
          f"no answer {sum(1 for r in results if not r['loop'])} of {len(results)}")
    if out_path:
        json.dump(results, open(out_path, "w"), indent=1)


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 1,
                     sys.argv[3] if len(sys.argv) > 3 else None))
