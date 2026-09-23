"""What did the send word-match override ever change? (hf-7)

Replays every distinct turn the classifier judged, from the app's
manager-events.jsonl, and compares its own intent with what the override in
Manager._turn would have forced. No model calls: the logged answers are what
Jev said at the time, and the override ran after them.

    uv run python drills/override_effect.py ~/Library/Application\\ Support/VoiceDispatch/manager-events.jsonl

On 23 Sep: 104 turns, the override fired on 5, and on all 5 Jev had already
chosen send_message. It changed nothing, so it was deleted rather than tuned.
"""

import json
import sys


def override_fires(text: str) -> bool:
    # The exact rule as it stood in manager.py before hf-7, kept here only to
    # measure it.
    low = text.lower()
    return "send" in low and any(w in low for w in ("message", "to this agent", "to the agent", "to it"))


def main(path: str) -> int:
    seen, turns = set(), []
    for raw in open(path, errors="replace"):
        try:
            e = json.loads(raw)
        except ValueError:
            continue
        if e.get("event") != "jev":
            continue
        text = (e.get("state") or {}).get("text_to_judge")
        if not text or text in seen:
            continue
        seen.add(text)
        turns.append((text, ((e.get("answers") or {}).get("intent") or {}).get("choice")))
    fired = [(t, i) for t, i in turns if override_fires(t)]
    changed = [(t, i) for t, i in fired if i != "send_message"]
    print(f"{len(turns)} distinct judged turns; override fired on {len(fired)}; changed the intent on {len(changed)}")
    for t, i in changed:
        print(f"  CHANGED {i} -> send_message :: {t[:100]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
