"""ElevenLabs TTS, with the spoken-text rules applied to every sentence, and every
sentence it speaks written to the transcript as the manager's own line. This is
the one place all of the manager's speech passes, whichever path produced it."""

from loguru import logger
from pipecat.frames.frames import AggregatedTextProgressFrame, Frame
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.elevenlabs.tts import ElevenLabsTTSService

from spoken import spoken


class SpokenTTSService(ElevenLabsTTSService):
    async def use_voice(self, voice_id: str | None):
        """Speak in somebody else's voice from here on.

        Every line this Mac says out loud now comes down the connection, so
        that the canceller has it and the microphone never has to close. That
        means the bot, not the app, reads a session's announcement — and it has
        to read it in that session's own voice, or every agent would suddenly
        sound like the manager.

        The socket bakes the voice into its URL, so a change of speaker costs a
        handshake — and `_update_settings` ALREADY does that handshake. `voice`
        is in `ElevenLabsTTSSettings.URL_FIELDS`, and the base class reconnects
        whenever a URL field changes. This asked for a second one on top, and
        two reconnects racing left a socket the service had not negotiated the
        output format with: everything after the first change of speaker came
        back at the wrong sample rate, so the whole session played high and
        fast, the manager's own voice included. One reconnect, done by the
        framework, is the entire operation.
        """
        if not voice_id or voice_id == self._settings.voice:
            return
        logger.info(f"voice: {self._settings.voice} -> {voice_id}")
        await self._update_settings(self.Settings(voice=voice_id))
        logger.info(f"voice: now {self._settings.voice} at {self._output_format}")

    async def push_frame(self, frame: Frame, direction: FrameDirection = FrameDirection.DOWNSTREAM):
        """Say how far along the voice is, so the panel can follow the words.

        The card highlights each word as it is spoken, and always has — driven
        by the local synthesiser's own callbacks. Hands-free moved the speaking
        to the bot, so those callbacks stopped existing and the card showed the
        words without ever lighting them up. The timings did not disappear;
        they moved here. ElevenLabs sends alignment as it plays, Pipecat turns
        it into one of these frames per word, and it carries exactly the thing
        the panel needs: the text spoken so far.

        A character count rather than a word index, because that is what the
        panel's `highlight(upTo:)` has taken since long before any of this and
        it does not have to learn a second way to be told.
        """
        if isinstance(frame, AggregatedTextProgressFrame):
            from events import emit
            await emit(None, "spoke", upTo=len(frame.accumulated_text),
                       text=frame.text)
        await super().push_frame(frame, direction)

    async def run_tts(self, text: str, context_id: str):
        clean = spoken(text)
        if clean != text.strip():
            logger.info(f"spoken: {text[:80]!r} -> {clean[:80]!r}")
        from manager import note  # late import: manager imports events, not tts
        from vocab import Line, LineKind, Role
        note(Line(Role.MANAGER, LineKind.SPOKEN, clean))
        async for frame in super().run_tts(clean, context_id):
            yield frame
