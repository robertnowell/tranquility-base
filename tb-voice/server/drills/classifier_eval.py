"""How well does the turn classifier judge real turns? (hf-7)

Replays labelled turns (the developer's own speech, kept outside git) through
the classifier exactly as production asks it (`JevClient.turn_request`), and
scores it against the labels, beside a candidate prompt (`candidate_request`,
the production prompt until you change it), so a prompt change is measured
before it ships.

A turn is addressed when p >= THRESHOLD. Scored per turn: addressed right or
wrong (a false yes acts on talk; a false no misses a command), and, for turns
that are addressed, whether the intent is one the label accepts. Ambiguous
labels (null) are skipped. Each turn is asked RUNS times per prompt, since
the classifier is not deterministic.

25 Sep, 101 turns x 3: the four rules that sat on top of the classifier
scored 291/303 with 6 false yeses; the classifier alone, told the same things
in its context, scored 290/303 with 3. The rules were deleted.

    JEV_API_KEY=... uv run python drills/classifier_eval.py <turns.jsonl> <gold.json> [runs]
"""

import asyncio
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from manager import THRESHOLD, JevClient, _chosen  # noqa: E402
from vocab import parse_intent  # noqa: E402


def stage_of(row) -> dict | None:
    s = row.get("stage")
    if not s:
        return None
    return s if isinstance(s, dict) else {"goal": s}


def candidate_request(utterance: str, before: list[dict], stage: dict | None) -> tuple[dict, dict]:
    """Change this to try a prompt; as committed it is production's."""
    return JevClient.turn_request(utterance, before, stage)


async def main(turns_path, gold_path, runs=1):
    rows = [json.loads(ln) for ln in open(turns_path)]
    gold = json.load(open(gold_path))["labels"]
    jev = JevClient(os.environ["JEV_API_KEY"])
    sem = asyncio.Semaphore(6)
    results = {"production": [], "candidate": []}

    async def ask(build, row):
        async with sem:
            for attempt in range(3):
                try:
                    a = await jev.ask(*build(row["text"], row["before"][-8:], stage_of(row)))
                    return float(a["addressed"]["noul"]), a["intent"]
                except Exception as e:  # a flaky call is retried, never scored
                    if attempt == 2:
                        raise
                    await asyncio.sleep(1 + attempt)

    async def one(row, r):
        g = gold[str(row["i"])]
        if g["addressed"] is None:
            return
        p, ans = await ask(JevClient.turn_request, row)
        cp, cans = await ask(candidate_request, row)
        readings = {"production": (p, parse_intent(_chosen(ans))), "candidate": (cp, parse_intent(_chosen(cans)))}
        for k, (pp, intent) in readings.items():
            said = pp >= THRESHOLD
            results[k].append({"i": row["i"], "run": r, "p": round(pp, 2), "intent": intent.value,
                               "addressed_ok": said == g["addressed"],
                               "false_yes": said and not g["addressed"], "false_no": g["addressed"] and not said,
                               "intent_ok": (not g["addressed"]) or (not said) or intent.value in g["intents"]})

    await asyncio.gather(*(one(row, r) for r in range(runs) for row in rows))

    scored = len(results["production"])
    print(f"{scored} judgements ({scored // runs} turns x {runs})\n")
    print(f"{'reading':<12}{'addressed right':>17}{'false yes':>11}{'false no':>10}{'intent wrong':>14}")
    for k, res in results.items():
        print(f"{k:<12}{sum(x['addressed_ok'] for x in res):>12}/{scored:<4}{sum(x['false_yes'] for x in res):>11}"
              f"{sum(x['false_no'] for x in res):>10}{sum(not x['intent_ok'] for x in res):>14}")
    print("\nwrong, by reading:")
    for k, res in results.items():
        bad = sorted({(x["i"], x["intent"], x["p"]) for x in res if not (x["addressed_ok"] and x["intent_ok"])})
        print(f"  {k}: " + ", ".join(f"{i}({intent} {p})" for i, intent, p in bad))
    out = os.path.join(os.path.dirname(gold_path), "eval-results.json")
    json.dump(results, open(out, "w"))
    print(f"\n(per-turn results: {out})")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 1))
