"""Speech, rather than microphone activity, starts an interrupting turn."""

import os

from pipecat.turns.user_start.min_words_user_turn_start_strategy import (
    MinWordsUserTurnStartStrategy,
)


def turn_start_strategy(*, cancels_echo: bool) -> MinWordsUserTurnStartStrategy:
    # With echo removed, even "Stop" or "Actually" is enough. A two-word
    # threshold discards each short transcription independently; it does not
    # accumulate them. Keep the more conservative default for other clients.
    default = "1" if cancels_echo else "2"
    return MinWordsUserTurnStartStrategy(min_words=int(os.getenv("TB_MIN_WORDS", default)))
