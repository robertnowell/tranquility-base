"""Cutting the manager off and giving it an order are not the same act.

Pipecat's MinWordsUserTurnStartStrategy needs MORE words while the bot is
speaking than while it is silent — `min_words if bot_speaking else 1`. That is
right for an assistant you are always addressing: a single noise-word should
not barge in on it, and in the quiet you are obviously talking to it.

This manager is the other way round. It sits in a room all day and is silent by
default, so a lone word in the quiet is almost never for it — "Next." and "the
next." once invited two agents from one sentence — while a lone word over its
voice is exactly how a person interrupts, and "Stop." is one word.

Measured 23 Sep against the shipped agent, one session:

    should_trigger=False num_spoken_words=1 min_words=2 bot_speaking=True   x10
    should_trigger=True  num_spoken_words=3 min_words=2 bot_speaking=True
    should_trigger=True  num_spoken_words=4 min_words=2 bot_speaking=True

Ten single words spoken over the manager, all discarded; the only two that got
through were three and four words long. That is what "interrupt doesn't work"
looks like from inside.

So: one word interrupts, two words start a turn from silence. The costs are
asymmetric and that is the whole argument. A word misheard over the voice stops
a sentence, which you were interrupting anyway, and it cannot run away because
the moment the voice stops there is nothing left to mishear. A word misheard in
the quiet invites an agent you did not ask for.
"""

from loguru import logger
from pipecat.frames.frames import InterimTranscriptionFrame, TranscriptionFrame
from pipecat.turns.types import ProcessFrameResult
from pipecat.turns.user_start.min_words_user_turn_start_strategy import (
    MinWordsUserTurnStartStrategy,
)


class InterruptOrCommandStrategy(MinWordsUserTurnStartStrategy):
    def __init__(self, *, min_words: int, interrupt_words: int = 1, **kwargs):
        """`min_words` starts a turn from silence; `interrupt_words` cuts the
        manager off. Named apart because they answer different questions."""
        super().__init__(min_words=min_words, **kwargs)
        self._interrupt_words = interrupt_words

    def words_needed(self) -> int:
        return self._interrupt_words if self._bot_speaking else self._min_words

    async def _handle_transcription(
        self, frame: TranscriptionFrame | InterimTranscriptionFrame
    ) -> ProcessFrameResult:
        needed = self.words_needed()
        count = len(frame.text.split())
        trigger = count >= needed
        logger.debug(
            f"{self} should_trigger={trigger} num_spoken_words={count} "
            f"words_needed={needed} bot_speaking={self._bot_speaking} "
            f"as={'interrupting' if self._bot_speaking else 'commanding'} "
            f"interim_transcription={isinstance(frame, InterimTranscriptionFrame)}"
        )
        if trigger:
            await self.trigger_user_turn_started()
            return ProcessFrameResult.STOP
        await self.trigger_reset_aggregation()
        return ProcessFrameResult.CONTINUE
