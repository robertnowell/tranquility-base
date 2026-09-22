"""ElevenLabs TTS, with the spoken-text rules applied to every sentence, and every
sentence it speaks written to the transcript as the manager's own line. This is
the one place all of the manager's speech passes, whichever path produced it."""

from loguru import logger
from pipecat.services.elevenlabs.tts import ElevenLabsTTSService

from spoken import spoken


class SpokenTTSService(ElevenLabsTTSService):
    async def run_tts(self, text: str, context_id: str):
        clean = spoken(text)
        if clean != text.strip():
            logger.info(f"spoken: {text[:80]!r} -> {clean[:80]!r}")
        from manager import note  # late import: manager imports events, not tts
        note("Tranquility", clean, "spoken")
        async for frame in super().run_tts(clean, context_id):
            yield frame
