"""The app's own sentence, coming back as the developer's.

A canceller subtracts the audio it played itself. The app's announcements — an
agent's line read aloud in that session's voice — go out through the app's own
synthesizer, not through the media connection, so they are not in the reference
and the microphone hears them the way it hears a person. On 23 Sep:

    20:03:40.556  app    "The cutover is complete; we're now researching AGI House SF…"
    20:03:50.016  heard  "The cutover is complete. We're now researching AGI. House SF"

three times in forty seconds, each judged as something the developer had said.

Closing the microphone while the app talks would fix it and is the wrong trade:
it is exactly the deafness the canceller exists to make unnecessary. So the
microphone stays open and the sentence is dropped afterwards instead — and only
that sentence. We know the app's line verbatim, because the manager composed it
before asking the app to read it, so this is a comparison against a known
string rather than a guess about what echo sounds like.

The real repair is upstream: play the app's voice through the same audio engine
the connection renders through, so the canceller has it in its reference and
nothing here has to fire. Until then this is the guard.
"""

import re
import time

from loguru import logger

import session

# How much of what was heard has to be found in what the app is saying. A
# transcript of the app's line comes back essentially whole — the three above
# matched every word — while a real command overlaps it only by accident:
# "Can you invite the next agent to speak?" shares one word with the line
# above, 0.12, so the bar sits far from both.
MATCH = 0.8
# The transcriber finalises after the speech ends, so the window has to outlast
# it. 8 s covers the worst of the three measured above by a wide margin.
LAG = 8.0
# Two or three words match too easily by chance to ever be judged this way.
MIN_WORDS = 4


def _words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def _in_order(heard: list[str], spoken: list[str]) -> float:
    """The share of the heard words that appear in the spoken line, in order."""
    i = found = 0
    for w in heard:
        try:
            i = spoken.index(w, i) + 1
            found += 1
        except ValueError:
            continue
    return found / len(heard)


def is_app_echo(text: str) -> bool:
    s = session.current()
    spoken = s.external_until.get("text") or ""
    if not spoken or time.monotonic() > s.external_until["t"] + LAG:
        return False
    heard = _words(text)
    if len(heard) < MIN_WORDS:
        return False
    share = _in_order(heard, _words(spoken))
    if share < MATCH:
        return False
    logger.info(f"dropped the app's own line back off the microphone ({share:.2f}): {text[:80]}")
    return True
