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

    # Three words of a sentence, as the service reports them.
    for spoken_so_far in ("It", "It is", "It is done."):
        await T.SpokenTTSService.push_frame(svc, AggregatedTextProgressFrame(
            segment_id=1, context_id="c", text=LINE, aggregated_by="word",
            accumulated_text=spoken_so_far, remaining_text=LINE[len(spoken_so_far):]))

    progress = [e for e in seen if e["event"] == "spoke"]
    check("one event per word spoken", len(progress) == 3)
    check("counted in characters, which is what the card takes",
          [e["upTo"] for e in progress] == [len(s) for s in ("It", "It is", "It is done.")])
    check("and it carries the line being spoken, so the card can check itself",
          all(e["text"] == LINE for e in progress))
    check("the frame still goes on down the pipeline", len(pushed) == 3)

    # Anything else passes through untouched and says nothing.
    seen.clear()
    await T.SpokenTTSService.push_frame(svc, TextFrame("hello"))
    check("a frame that is not progress reports nothing", seen == [])

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
