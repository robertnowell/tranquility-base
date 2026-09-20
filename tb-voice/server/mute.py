"""Mute the mic while the bot speaks, and for a beat after.

Local audio has no echo cancellation: the manager's own voice through the
speakers came back in as "the user started speaking", interrupted it, and
cancelled the handler mid-flight (16:49:39 and 16:49:59). While the bot is
talking the user's frames are dropped; the tail covers room reverb. A person who
really wants to cut in says "stop" once the line ends, or taps a chord.
"""

import time

from pipecat.frames.frames import BotStartedSpeakingFrame, BotStoppedSpeakingFrame, Frame
from pipecat.turns.user_mute.base_user_mute_strategy import BaseUserMuteStrategy

# The manager sets this when it hands the app a line to speak in a session's
# voice; the app's audio is echo too, and the bot never sees its frames.
EXTERNAL_UNTIL = {"t": 0.0}


class WhileBotSpeaksMuteStrategy(BaseUserMuteStrategy):
    def __init__(self, tail_secs: float = 0.6):
        super().__init__()
        self._speaking = False
        self._stopped_at = 0.0
        self._tail = tail_secs

    async def process_frame(self, frame: Frame) -> bool:
        await super().process_frame(frame)
        if isinstance(frame, BotStartedSpeakingFrame):
            self._speaking = True
        elif isinstance(frame, BotStoppedSpeakingFrame):
            self._speaking = False
            self._stopped_at = time.monotonic()
        return (self._speaking or (time.monotonic() - self._stopped_at) < self._tail
                or time.monotonic() < EXTERNAL_UNTIL["t"])
