"""Which of the developer's lines a send may point at (hf-26, revised 29 Sep).

The failure this drills is not in the picker, which behaved correctly, but in
the list it was shown. At 17:01 on 29 Sep the developer asked a question out
loud, the manager answered it, and he then said "send that message, everything
I just said, to the agent". The question had been classified COMMAND -- said to
the manager -- and COMMAND lines were not candidates, so the picker was shown
three fragments and answered none. Nothing was sent.

    uv run python drills/candidate_drill.py
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import span  # noqa: E402

# The ledger the Mac served at 17:01:47, as it served it.
LEDGER = [
    {"n": 11, "role": "user", "kind": "talk", "text": "Okay, let's"},
    {"n": 12, "role": "user", "kind": "talk", "text": "Let's see. We want to say."},
    {"n": 13, "role": "user", "kind": "talk", "text": "Oh, can we start?"},
    {"n": 14, "role": "user", "kind": "command",
     "text": "And is this going to be deterministic per run or non-deterministic? Per run."},
    {"n": 15, "role": "agent", "kind": "spoken", "text": "The record does not say."},
    {"n": 16, "role": "manager", "kind": "spoken", "text": "The record does not say."},
    {"n": 17, "role": "user", "kind": "command",
     "text": "You know, send that message, everything I just said, to the agent."},
]
REQUEST = "You know, send that message, everything I just said, to the agent."

fails = 0


def ok(claim: str, cond: bool):
    global fails
    print(f"   {'ok   ' if cond else 'FAIL '} {claim}")
    fails += 0 if cond else 1


cands = span.from_ledger_rows(LEDGER, REQUEST)
nums = [c.n for c in cands]

ok("the question he wanted sent is a candidate", 14 in nums)
ok("and it is marked as said to the manager", any(c.n == 14 and c.to_manager for c in cands))
ok("his talk lines are still candidates", [11, 12, 13] == nums[:3])
ok("the request's own line is not a candidate", 17 not in nums)
ok("nothing said by the manager or an agent is", all(n not in nums for n in (15, 16)))
ok("the marker is in the list the model reads", "(said to you) And is this" in span.numbered(cands))
ok("an unmarked line carries no marker", "(said to you) Okay" not in span.numbered(cands))

pick = span.check({"lines": [14, 14]}, cands, REQUEST)
ok("pointing at it checks out", pick is not None)
ok("and the text is his, copied", pick is not None and span.text_of(pick, cands) == LEDGER[3]["text"])

# The request line is dropped on identity -- the same utterance, whatever the
# transcriber did about case and punctuation -- and never on resemblance. A
# second, differently worded instruction stays a candidate, and what keeps it
# out of a message is the picker's own rule ("a line that only directs a send
# never is"), measured none in 3 of 3 runs on 29 Sep. Dropping by resemblance
# would be how a real line that happens to read like an instruction disappears.
loud = dict(LEDGER[6], text="SEND THAT MESSAGE,  everything I just said... to the agent!")
ok("the same utterance is dropped however it was punctuated",
   17 not in [c.n for c in span.from_ledger_rows(LEDGER[:6] + [loud], loud["text"])])
also = LEDGER + [{"n": 18, "role": "user", "kind": "command", "text": "Send it over to it, please."}]
ok("a differently worded instruction is still a candidate",
   18 in [c.n for c in span.from_ledger_rows(also, REQUEST)])

print("FAIL" if fails else "PASS")
sys.exit(1 if fails else 0)
