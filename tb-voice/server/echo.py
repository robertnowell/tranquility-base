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
        # It still needs one for the app's voice. A canceller can only remove
        # what it played itself, and the app's announcements — an agent's line
        # read aloud in that session's voice — go out through the app's own
        # synthesizer, not through the media connection. They are not in the
        # reference signal, so nothing subtracts them, and the microphone hears
        # them the way it hears a person. On 23 Sep at 20:03:40 the app said
        # "The cutover is complete; we're now researching AGI House SF…" and ten
        # seconds later the manager transcribed it back, verbatim, as something
        # the developer had said; three announcements in a row came back the
        # same way. Turning the whole gate off at the WebRTC cutover is what
        # exposed this: the app-speech window went with it.
        self._cancels_own_voice = cancels_own_voice

    def gated(self) -> bool:
        now = time.monotonic()
        s = session.current()
        if now < s.external_until["t"] + self._tail:
            return True
        if self._cancels_own_voice:
            return False
        return (s.bot_voice["speaking"] or (now - s.bot_voice["stopped_at"]) < self._tail)

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
