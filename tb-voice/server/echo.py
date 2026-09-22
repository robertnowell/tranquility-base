"""Feed the transcriber silence while any voice is playing.

The aggregator's mute drops transcriptions only while it is muted, but a
streaming STT finalises late: at 17:26:42 Gradium delivered fifteen seconds of
the manager's own speech ("Listening. 11 waiting on you… I manage voice loops
for") six seconds after the bot went quiet, past the 0.6 s tail, and it was
judged as the developer asking to send a message. So the echo is removed
before the STT ever hears it: while the bot speaks, for a beat after, and while
the app speaks in a session's voice, the mic frames go through as zeros. Zeros
rather than nothing, so the STT's own endpointing sees continuous audio and
closes the turn cleanly.
"""

import time

from loguru import logger

from pipecat.frames.frames import Frame, InputAudioRawFrame
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from mute import BOT_VOICE, EXTERNAL_UNTIL


class EchoGate(FrameProcessor):
    def __init__(self, tail_secs: float = 0.6, passthrough: bool = False, **kwargs):
        super().__init__(**kwargs)
        self._tail = tail_secs
        self._was_gated = False
        # A client whose microphone already has our voice subtracted from it
        # needs no gate, and a gate would make it impossible to interrupt the
        # manager: while it speaks, nothing said would ever be transcribed.
        self._passthrough = passthrough

    def gated(self) -> bool:
        if self._passthrough:
            return False
        now = time.monotonic()
        return (BOT_VOICE["speaking"] or (now - BOT_VOICE["stopped_at"]) < self._tail
                or now < EXTERNAL_UNTIL["t"])

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, InputAudioRawFrame):
            gated = self.gated()
            if gated != self._was_gated:
                self._was_gated = gated
                logger.info(f"echo gate {'closed' if gated else 'open'}")
            if gated:
                frame.audio = bytes(len(frame.audio))
        await self.push_frame(frame, direction)
