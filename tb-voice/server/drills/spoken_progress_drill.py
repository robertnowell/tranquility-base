"""The panel is told how far through a line the voice has got.

The card highlights each word as it is spoken and always has, driven by the
local synthesiser's callbacks. Hands-free moved the speaking to the bot, so
those callbacks stopped existing: the card showed the words and never lit them.
The timings did not disappear, they moved — ElevenLabs sends alignment as it
plays and Pipecat turns it into one frame per word.

This drives the translation: a progress frame in, an event the app already
knows how to paint out. A character count, because `highlight(upTo:)` has taken
one since long before any of this.
"""
import asyncio, sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

from pipecat.frames.frames import AggregatedTextProgressFrame, TextFrame

import events
import tts as T

LINE = "It is done. Ship it?"


async def main() -> int:
    fails = []
    seen: list[dict] = []
    events.line = lambda event, **f: seen.append({"event": event, **f}) or {"event": event, **f}

    def check(what, ok):
        print(f"   {'ok  ' if ok else 'FAIL'}  {what}")
        if not ok:
            fails.append(what)

    svc = T.SpokenTTSService.__new__(T.SpokenTTSService)
    pushed: list = []

    async def passthrough(self, frame, direction=None):
        pushed.append(frame)

    # The parent's push_frame is what ours calls after emitting.
    T.ElevenLabsTTSService.push_frame = passthrough

    # Three words of a sentence, as the service reports them -- each stamped
    # with when it is MEANT to be heard. ElevenLabs hands the whole alignment
    # over at once, so all three arrive in the same tick and only these
    # timestamps say they are half a second apart.
    for i, spoken_so_far in enumerate(("It", "It is", "It is done.")):
        f = AggregatedTextProgressFrame(
            segment_id=1, context_id="c", text=LINE, aggregated_by="word",
            accumulated_text=spoken_so_far, remaining_text=LINE[len(spoken_so_far):])
        f.pts = int(i * 0.5 * 1_000_000_000)   # 0.0s, 0.5s, 1.0s, in nanoseconds
        await T.SpokenTTSService.push_frame(svc, f)

    progress = [e for e in seen if e["event"] == "spoke"]
    check("one event per word spoken", len(progress) == 3)
    check("counted in characters, which is what the card takes",
          [e["upTo"] for e in progress] == [len(s) for s in ("It", "It is", "It is done.")])
    # Reversed 27 Sep. It carried the whole line with every word, so an
    # eight-word sentence put the same paragraph on the wire eight times and
    # the viewer printed all eight -- a screen of one repeated sentence where
    # a progress bar belonged. The card already has the line from the
    # `speaking` event that preceded this; progress is a number.
    check("it carries progress and nothing else",
          all("text" not in e for e in progress))
    # The half that 28 Sep added. Without a time the panel paints on arrival,
    # and since every event arrives together the line flashes in at once and
    # then waits for the voice.
    check("and WHEN each word is meant to be heard, in seconds",
          [e.get("at") for e in progress] == [0.0, 0.5, 1.0])

    # A frame with no timestamp still reports, because a panel painting on
    # arrival is worse than a panel painting nothing but not by much, and an
    # older bot must not go dark.
    seen.clear()
    bare = AggregatedTextProgressFrame(
        segment_id=1, context_id="c", text=LINE, aggregated_by="word",
        accumulated_text="It", remaining_text=LINE[2:])
    await T.SpokenTTSService.push_frame(svc, bare)
    check("a frame with no timestamp still reports its progress",
          len(seen) == 1 and seen[0]["upTo"] == 2 and seen[0].get("at") is None)
    # Four: the three timed words above, plus the untimed one. Every progress
    # frame is reported AND forwarded -- this service listens, it does not
    # consume.
    check("every frame still goes on down the pipeline", len(pushed) == 4)

    # Anything else passes through untouched and says nothing.
    seen.clear()
    await T.SpokenTTSService.push_frame(svc, TextFrame("hello"))
    check("a frame that is not progress reports nothing", seen == [])

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
