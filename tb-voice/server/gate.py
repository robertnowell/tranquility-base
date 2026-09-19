"""The addressed gate: silence by default.

Every finished user turn arrives here as an LLMContextFrame. The user aggregator has
already appended the words to the context, so swallowing the frame keeps them as context
and runs nothing. Jev (TypeSafe's decision model) answers one yes/no question per turn;
only a "yes" lets the frame reach the LLM. See docs/design.md section 2.
"""

import json
import os
import time

import httpx
from loguru import logger
from pipecat.frames.frames import Frame, LLMContextFrame
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

JEV_URL = "https://api.typesafe.ai/v1/systemone"
NAME = os.getenv("TB_MANAGER_NAME", "Base")
THRESHOLD = float(os.getenv("TB_ADDRESSED_THRESHOLD", "0.5"))

CONTEXT = (
    f"The assistant is a voice manager named {NAME}. It listens to a developer thinking "
    "aloud while supervising a fleet of coding agents, and speaks only when addressed."
)
QUESTION = {
    "type": "noul",
    "instructions": (
        f"Is the speaker addressing the assistant {NAME} directly, with a request or a "
        "question meant for it?"
    ),
    "criteria": {
        "true": f"Names {NAME}, or asks or instructs the assistant directly",
        "false": (
            "Thinking aloud, a rhetorical question, talking to another person, or the "
            f"word {NAME.lower()} used for something else"
        ),
    },
}


class JevClient:
    def __init__(self, api_key: str):
        self._client = httpx.AsyncClient(
            headers={"Authorization": f"Bearer {api_key}"}, timeout=8.0
        )

    async def addressed(self, utterance: str, recent: list[str]) -> float:
        body = {
            "state": {"context": CONTEXT, "recent_turns": recent[-3:], "utterance": utterance},
            "model": "jev-latest",
            "questions": {"addressed": QUESTION},
        }
        r = await self._client.post(JEV_URL, json=body)
        r.raise_for_status()
        return float(r.json()["answers"]["addressed"]["noul"])


class AddressedGate(FrameProcessor):
    """Passes LLMContextFrame only when Jev says the manager was addressed."""

    def __init__(self, jev: JevClient, on_verdict=None):
        super().__init__()
        self._jev = jev
        self._on_verdict = on_verdict
        self.heard = 0
        self.addressed = 0
        self._recent: list[str] = []

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if not isinstance(frame, LLMContextFrame) or frame.speculation:
            if isinstance(frame, LLMContextFrame):
                return  # speculative runs would speak early; the gate owns timing
            await self.push_frame(frame, direction)
            return

        text = _last_user_text(frame)
        if not text:
            await self.push_frame(frame, direction)
            return

        self.heard += 1
        t0 = time.monotonic()
        try:
            p = await self._jev.addressed(text, self._recent)
        except Exception as e:  # a gate that fails must fail closed: silence
            logger.warning(f"jev failed ({e}); staying silent")
            p = 0.0
        ms = int((time.monotonic() - t0) * 1000)
        self._recent.append(text)
        speak = p >= THRESHOLD
        self.addressed += int(speak)
        logger.info(f"gate p={p:.2f} {ms}ms {'SPEAK' if speak else 'silent'} :: {text[:80]}")
        if self._on_verdict:
            await self._on_verdict(text, p, speak, ms)
        if speak:
            await self.push_frame(frame, direction)
        # else: the words are already in the context; nothing else happens.


def _last_user_text(frame: LLMContextFrame) -> str:
    for m in reversed(frame.context.get_messages()):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, str):
                return c
            if isinstance(c, list):
                return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            return ""
    return ""
