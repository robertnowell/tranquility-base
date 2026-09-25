"""How well does the turn classifier judge real turns? (hf-7)

Replays labelled turns (the developer's own speech, kept outside git) through
the classifier exactly as production asks it (`JevClient.turn_request`), and
scores it against the labels beside main as of e32148c (its prompt and the
four rules it had on top, frozen below), and optionally a candidate prompt
(EVAL_CANDIDATE=1, `candidate_request`), so a prompt change is measured before
it ships.

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

from manager import INTENTS, NAME, THRESHOLD, JevClient, _chosen  # noqa: E402
from vocab import Intent, parse_intent  # noqa: E402


def stage_of(row) -> dict | None:
    s = row.get("stage")
    if not s:
        return None
    return s if isinstance(s, dict) else {"goal": s}


def candidate_request(utterance: str, before: list[dict], stage: dict | None) -> tuple[dict, dict]:
    """Change this to try a prompt; as committed it is production's."""
    return JevClient.turn_request(utterance, before, stage)


# main as of e32148c, frozen here as the baseline #629 is measured against:
# its prompt, its intent list (no fleet_status), and the four rules on top.
MAIN_TEACH = "Asks what the manager can do, what this is, or how it works"


def main_request(utterance: str, before: list[dict], stage: dict | None) -> tuple[dict, dict]:
    state = {
        "context": (f"The assistant is a voice manager named {NAME}. It listens to a developer "
                    "thinking aloud while supervising a fleet of coding agents, and speaks only "
                    "when addressed. Lines marked 'you' are the developer; other lines were spoken "
                    "by the assistant or by an agent, and the developer heard them."),
        "conversation_before": before,
        "agent_on_stage": (stage or {}).get("goal"),
        "text_to_judge": utterance,
        "rules": (
            "Judge ONLY text_to_judge. conversation_before is context: 'you' is the developer, "
            "other names are the assistant or an agent speaking; a status of 'acted' or 'spoken' "
            "means that turn was already handled and must not be acted on again. "
            f"The transcriber often misspells the name {NAME}: Drinkody, Tranquillity, Tranquilly, "
            "Tranquil, Trank; a turn opening with such a word is addressed."),
    }
    intents = {i.value: (MAIN_TEACH if i is Intent.TEACH else d) for i, d in INTENTS.items()
               if i is not Intent.FLEET_STATUS}
    return state, {
        "addressed": {"type": "noul",
            "instructions": (f"In text_to_judge, is the developer asking the assistant {NAME} to speak "
                             "or act RIGHT NOW? Earlier turns do not count; only this text."),
            "criteria": {"true": (f"Names {NAME}, or asks or instructs the assistant directly"
                                  + (", or asks about the agent on stage: its goal, findings, next step, reasons, or tells it to do something"
                                     if stage else "")),
                         "false": ("Thinking aloud, a rhetorical question, talking to another "
                                   f"person, reading text aloud, or the word {NAME.lower()} used for something else")}},
        "intent": {"type": "choice",
            "instructions": "If text_to_judge is a request to the assistant, which kind is it?",
            "criteria": intents},
    }


_NAME_SOUNDS = ("tranq", "trank", "drink", "tranc", "trinq", "tranguil", "tranqu")
_COMMANDS = {"invite_next", "send_message", "start_agent", "take_note", "rung_goal", "rung_findings",
             "rung_solution", "rung_why", "summarize_recent", "mute"}
_STAGE_QUESTIONS = {"rung_goal", "rung_findings", "rung_solution", "rung_why", "custom", "send_message"}


def main_decide(text: str, p: float, answer: dict, stage) -> tuple[float, Intent]:
    intent = parse_intent(_chosen(answer))
    if not stage and intent.value.startswith("rung_"):
        intent = Intent.INVITE_NEXT
    conf = float(answer.get("confidence", 0))
    words = [w.strip(",.!?;:").lower() for w in text.split()[:2]]
    if words and words[0].startswith(_NAME_SOUNDS) and (len(words) < 2 or words[1] != "base"):
        return max(p, 0.95), intent
    if intent.value in _COMMANDS and conf >= 0.9 and p >= 0.3:
        return max(p, 0.6), intent
    if stage and intent.value in _STAGE_QUESTIONS and conf >= 0.8 and p >= 0.3:
        return max(p, 0.6), intent
    return p, intent


READINGS = {
    "main": (main_request, main_decide),
    "#629": (JevClient.turn_request, lambda text, p, a, stage: (p, parse_intent(_chosen(a)))),
}
if os.getenv("EVAL_CANDIDATE"):
    READINGS["candidate"] = (candidate_request, lambda text, p, a, stage: (p, parse_intent(_chosen(a))))


async def main(turns_path, gold_path, runs=1):
    rows = [json.loads(ln) for ln in open(turns_path)]
    gold = json.load(open(gold_path))["labels"]
    jev = JevClient(os.environ["JEV_API_KEY"])
    sem = asyncio.Semaphore(6)
    results = {k: [] for k in READINGS}

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
        for k, (build, decide) in READINGS.items():
            p, ans = await ask(build, row)
            pp, intent = decide(row["text"], p, ans, stage_of(row))
            said = pp >= THRESHOLD
            results[k].append({"i": row["i"], "run": r, "p": round(pp, 2), "intent": intent.value,
                               "addressed_ok": said == g["addressed"],
                               "false_yes": said and not g["addressed"], "false_no": g["addressed"] and not said,
                               "intent_ok": (not g["addressed"]) or (not said) or intent.value in g["intents"]})

    await asyncio.gather(*(one(row, r) for r in range(runs) for row in rows))

    scored = len(results["main"])
    print(f"{scored} judgements ({scored // runs} turns x {runs})\n")
    print(f"{'reading':<12}{'addressed right':>17}{'false yes':>11}{'false no':>10}{'intent wrong':>14}")
    for k, res in results.items():
        print(f"{k:<12}{sum(x['addressed_ok'] for x in res):>12}/{scored:<4}{sum(x['false_yes'] for x in res):>11}"
              f"{sum(x['false_no'] for x in res):>10}{sum(not x['intent_ok'] for x in res):>14}")
    print("\nwrong, by reading:")
    for k, res in results.items():
        bad = sorted({(x["i"], x["intent"], x["p"]) for x in res if not (x["addressed_ok"] and x["intent_ok"])})
        print(f"  {k}: " + ", ".join(f"{i}({intent} {p})" for i, intent, p in bad))
    out = os.path.splitext(gold_path)[0] + "-results.json"
    json.dump(results, open(out, "w"))
    print(f"\n(per-turn results: {out})")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 1))
