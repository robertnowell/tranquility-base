"""Replay short interruptions against the real production turn-start strategy.

Run from server: uv run python drills/first_word_drill.py
No microphone, network calls, service keys, or application state required.
"""

import asyncio
import os
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    InterimTranscriptionFrame,
    TranscriptionFrame,
    VADUserStartedSpeakingFrame,
)
from turn_start import turn_start_strategy


async def exercise(cancels_echo, frames, expected, override=None):
    with patch.dict(os.environ):
        os.environ.pop("TB_MIN_WORDS", None)
        if override is not None:
            os.environ["TB_MIN_WORDS"] = override
        strategy = turn_start_strategy(cancels_echo=cancels_echo)
    interruptions = []

    @strategy.event_handler("on_user_turn_started")
    async def started(sender, params):
        interruptions.append(params.enable_interruptions)

    await strategy.process_frame(BotStartedSpeakingFrame())
    for frame, count in zip(frames, expected, strict=True):
        await strategy.process_frame(frame)
        assert len(interruptions) == count, (frame, interruptions, count)
        assert all(interruptions), "Turn started without enabling interruption"


def transcript(text, *, interim=False):
    cls = InterimTranscriptionFrame if interim else TranscriptionFrame
    return cls(text=text, user_id="user", timestamp="2026-09-23T19:44:14Z")


async def main():
    # The incident's first fragment must interrupt, before the eventual sentence.
    for text in ("Actually,", "Stop.", "Wait."):
        for interim in (True, False):
            await exercise(True, [transcript(text, interim=interim)], [1])
    # Ambient VAD and an empty transcript still cannot cancel the answer.
    await exercise(True, [VADUserStartedSpeakingFrame(), transcript(" "),
                          transcript("Actually,", interim=True)], [0, 0, 1])
    # Preserve the existing conservative path and explicit operator override.
    for echo, override in ((False, None), (True, "2")):
        await exercise(echo, [transcript("Actually,"), transcript("Yeah."),
                              transcript("I'm going to interact.")], [0, 0, 1], override)
    print("first-word interruption: PASS (9 scenarios)")


asyncio.run(main())
