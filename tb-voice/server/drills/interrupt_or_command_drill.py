"""One word cuts the manager off; two words give it an order.

23 Sep, from the shipped agent's own log, one session:

    should_trigger=False num_spoken_words=1 min_words=2 bot_speaking=True   x10
    should_trigger=True  num_spoken_words=3 min_words=2 bot_speaking=True
    should_trigger=True  num_spoken_words=4 min_words=2 bot_speaking=True

Ten single words spoken over the manager, every one discarded. That is what
"interrupt doesn't work during announcements" looks like from inside, and it is
Pipecat's default rule — more words to interrupt than to command — which is
right for an assistant you are always addressing and backwards for a manager
that sits silent in a room.
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from turn_start import InterruptOrCommandStrategy


def main() -> int:
    s = InterruptOrCommandStrategy(min_words=2, interrupt_words=1)
    fails = []

    def check(what, got, want):
        print(f"   {'ok  ' if got == want else 'FAIL'}  {what}: {got}" + ("" if got == want else f", wanted {want}"))
        if got != want:
            fails.append(what)

    print("over the manager's voice — a cut-off is a cut-off")
    s._bot_speaking = True
    check('"Stop." interrupts', s.words_needed() <= 1, True)

    print("into the quiet — a lone word is almost never for it")
    s._bot_speaking = False
    check('"Next." alone does not start a turn', s.words_needed() > 1, True)
    check('"What is next?" does', s.words_needed() <= 3, True)

    print("and the two are independent, which is the whole point")
    tight = InterruptOrCommandStrategy(min_words=4, interrupt_words=1)
    tight._bot_speaking = True
    check("raising the command bar leaves interruption at one", tight.words_needed(), 1)
    tight._bot_speaking = False
    check("and the command bar is what was raised", tight.words_needed(), 4)

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())
