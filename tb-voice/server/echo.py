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

import session


class EchoGate(FrameProcessor):
    def __init__(self, tail_secs: float = 0.6, cancels_own_voice: bool = False, **kwargs):
        super().__init__(**kwargs)
        self._tail = tail_secs
        self._was_gated = False
        # A client whose microphone already has OUR voice subtracted from it
        # needs no gate for the manager's own speech, and a gate there would
        # make it impossible to interrupt: while it spoke, nothing said would
        # ever be transcribed.
        #
        # The app's announcements are a different problem and are NOT solved
        # here. They go out through the app's own synthesizer rather than the
        # media connection, so they are not in the canceller's reference and
        # nothing subtracts them; on 23 Sep the manager transcribed three of
        # them back, verbatim, as the developer's speech. The answer is not to
        # close the microphone — the whole point of a canceller is that the
        # microphone stays open — and it is not to compare transcripts against
        # the line being read either. It is that the app has no second set of
        # speakers: ManagerAudio renders its voice through the engine the
        # connection renders through, so the canceller subtracts it like any
        # other audio we play.
        self._cancels_own_voice = cancels_own_voice

    def gated(self) -> bool:
        if self._cancels_own_voice:
            return False
        now = time.monotonic()
        s = session.current()
        return (s.bot_voice["speaking"] or (now - s.bot_voice["stopped_at"]) < self._tail
                or now < s.external_until["t"] + self._tail)

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
