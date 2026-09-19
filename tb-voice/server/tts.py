"""Gradium TTS, with the spoken-text rules applied to every sentence."""

from pipecat.services.gradium.tts import GradiumTTSService

from spoken import spoken


class SpokenGradiumTTSService(GradiumTTSService):
    async def run_tts(self, text: str, context_id: str):
        clean = spoken(text)
        if clean != text.strip():
            from loguru import logger
            logger.info(f"spoken: {text[:80]!r} -> {clean[:80]!r}")
        async for frame in super().run_tts(clean, context_id):
            yield frame
