"""Does the span picker send what was said, and only that? (hf-8)

Runs Brain.pick_span and span.check over labelled real sends: the request,
the developer's lines before it, and what should have gone out (nothing, a
range ending at a known line, or a quote containing known words). Each case
runs several times; the model is at temperature 0 but not deterministic.

    GC_API_KEY=... uv run python drills/span_eval.py cases.json [runs]

The cases are the developer's own speech, so they live outside the repo.
Scoring, worst first:
  WRONG   something was sent that is not the message (the failure that matters)
  MISSED  the message existed and nothing was sent (the manager keeps listening)
  OK      what should have been sent, or nothing when nothing was said
"""

import asyncio
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import span  # noqa: E402
from manager import Brain  # noqa: E402


def score(case: dict, pick: span.Pick | None, cands: list[span.Candidate]) -> str:
    e = case["expect"]
    if pick is None:
        return "OK" if e["kind"] == "none" else "MISSED"
    if e["kind"] == "none":
        return "WRONG"
    text = span.text_of(pick, cands)
    if e["kind"] == "quote":
        return "OK" if e["has"] in text else "WRONG"
    if pick.lines is None:
        return "WRONG"
    by_n = {c.n: c.text for c in cands}
    first, last = by_n.get(pick.lines[0]), by_n.get(pick.lines[1])
    return "OK" if last == e["last"] and first in e["first_any"] else "WRONG"


async def main(path: str, runs: int):
    cases = json.load(open(path))
    brain = Brain()
    totals = {"OK": 0, "MISSED": 0, "WRONG": 0}
    latencies: list[int] = []
    for case in cases:
        cands = [span.Candidate(n=c["n"], text=c["text"]) for c in case["cands"]]
        results = []
        for _ in range(runs):
            t0 = time.monotonic()
            try:
                answer = await brain.pick_span(case["request"], cands, case["agent"], case.get("goal"))
            except Exception as e:  # a timeout sends nothing: the manager keeps listening
                answer = {"error": type(e).__name__}
            ms = int((time.monotonic() - t0) * 1000)
            latencies.append(ms)
            pick = span.check(answer if "error" not in (answer or {}) else None, cands, case["request"])
            verdict = score(case, pick, cands)
            totals[verdict] += 1
            results.append((verdict, answer, ms))
        worst = "WRONG" if any(r[0] == "WRONG" for r in results) else ("MISSED" if any(r[0] == "MISSED" for r in results) else "OK")
        print(f"{worst:6} #{case['i']:<3} {max(r[2] for r in results):>5} ms  {case['request'][:64]}")
        if worst != "OK":
            for v, a, ms in results:
                print(f"         {v} {ms} ms: {a}")
    n = sum(totals.values())
    latencies.sort()
    print(f"latency p50 {latencies[len(latencies) // 2]} ms, max {latencies[-1]} ms")
    print(f"\n{n} picks over {len(cases)} real sends x {runs}: OK {totals['OK']}, MISSED {totals['MISSED']}, WRONG {totals['WRONG']}")
    sys.exit(1 if totals["WRONG"] else 0)


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 3))
