"""The manager's loop (hf-6): one model, tools, several steps.

A question used to get one completion over whatever had been fetched for it in
advance (the brief, the transcript's tail) and had no way to look further, so
"what happens if these changes go badly?" was answered "the facts don't say"
while the agent's transcript said. And questions with nobody on stage went to
a second model path, Pipecat's tool-calling LLM, which could also type its own
words into an agent. Now a question is a loop:

    model -> tool calls (several at once) -> results -> model ... -> answer

capped at MAX_STEPS model calls and BUDGET_S seconds. Every tool reads; none
acts. Acting (a send, a start, an invite) stays with the handlers that own it,
so nothing here can type into an agent. When the loop is still working after
HOLD_AFTER_S and starts a tool, the caller is told once, so it can say a
holding line instead of leaving the room silent.
"""

import asyncio
import json
import os
import re
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

import httpx
from loguru import logger

from calls import record

MAX_STEPS = int(os.getenv("TB_LOOP_STEPS", "6"))
BUDGET_S = float(os.getenv("TB_LOOP_BUDGET_S", "8"))
HOLD_AFTER_S = float(os.getenv("TB_LOOP_HOLD_AFTER_S", "1.5"))
RESULT_CAP = 12_000  # characters of one tool result the model sees


@dataclass
class Tool:
    name: str
    description: str
    run: Callable[[dict], Awaitable[Any]]
    params: dict = field(default_factory=dict)  # JSON schema properties
    required: list[str] = field(default_factory=list)
    holding: str = "Checking."  # said once when this tool starts late

    def schema(self) -> dict:
        return {"type": "function", "function": {
            "name": self.name, "description": self.description,
            "parameters": {"type": "object", "properties": self.params, "required": self.required}}}


@dataclass
class Outcome:
    answer: str | None
    steps: int
    calls: list[dict]
    stopped: str | None = None  # "steps" | "time" | "error" when there is no answer
    ms: int = 0


_THINK = re.compile(r"<think>.*?</think>", re.S)
# Offered no tools on its last step, the model sometimes writes the call it
# wanted as text in its own markup (25 Sep, a sixth step: "<minimax:tool_call>
# <invoke name=..."). That is not an answer, and it must never be spoken.
_CALL_TEXT = re.compile(r"<(\w+:)?tool_call>.*?(</(\w+:)?tool_call>|$)|<invoke\b.*?(</invoke>|$)", re.S)


def _clean(text: str | None) -> str:
    return " ".join(_CALL_TEXT.sub("", _THINK.sub("", text or "")).split())


class Loop:
    def __init__(self, client: httpx.AsyncClient | None = None, model: str | None = None):
        self._client = client or httpx.AsyncClient(
            base_url=os.getenv("GC_BASE_URL", "https://api.generalcompute.com/v1"),
            headers={"Authorization": f"Bearer {os.environ.get('GC_API_KEY', '')}"})
        self.model = model or os.getenv("GC_MODEL", "minimax-m2.7")

    async def run(self, system: str, user: str, tools: list[Tool], *,
                  on_hold: Callable[[str], Awaitable[None]] | None = None,
                  max_steps: int = MAX_STEPS, budget_s: float = BUDGET_S,
                  max_words: int | None = None) -> Outcome:
        t0 = time.monotonic()
        deadline = t0 + budget_s
        by_name = {t.name: t for t in tools}
        messages: list[dict] = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        calls: list[dict] = []
        held = False

        def done(answer, steps, stopped=None):
            return Outcome(answer, steps, calls, stopped, int((time.monotonic() - t0) * 1000))

        for step in range(1, max_steps + 1):
            left = deadline - time.monotonic()
            if left <= 0:
                return done(None, step - 1, "time")
            # The last step gets no tools: it has to answer from what it has.
            offer = [t.schema() for t in tools] if step < max_steps else []
            body = {"model": self.model, "messages": messages, "max_tokens": 600, "temperature": 0.2}
            if offer:
                body["tools"] = offer
            try:
                c0 = time.monotonic()
                r = await self._client.post("/chat/completions", json=body, timeout=left)
                r.raise_for_status()
                reply = r.json()
                record("loop", body, reply, ms=int((time.monotonic() - c0) * 1000))
            except (httpx.HTTPError, ValueError) as e:
                logger.error(f"loop step {step}: {e}")
                return done(None, step, "time" if isinstance(e, httpx.TimeoutException) else "error")
            msg = reply["choices"][0]["message"]
            wanted = msg.get("tool_calls") or []
            if not wanted:
                answer = _clean(msg.get("content")) or None
                if answer is None and step == max_steps:
                    return done(None, step, "steps")
                if answer and max_words and len(answer.split()) > max_words:
                    answer = await self._shorten(messages, answer, max_words, deadline) or answer
                return done(answer, step)
            messages.append({"role": "assistant", "content": msg.get("content") or "", "tool_calls": wanted})
            if on_hold and not held and time.monotonic() - t0 >= HOLD_AFTER_S:
                held = True
                first = by_name.get(wanted[0]["function"]["name"])
                await on_hold(first.holding if first else "Checking.")

            async def one(call):
                name = call["function"]["name"]
                c0 = time.monotonic()
                try:
                    args = json.loads(call["function"].get("arguments") or "{}")
                except ValueError:
                    args, result = {}, {"error": "arguments were not JSON"}
                else:
                    tool = by_name.get(name)
                    if tool is None:
                        result = {"error": f"no tool named {name}"}
                    else:
                        try:
                            result = await asyncio.wait_for(tool.run(args), max(0.1, deadline - time.monotonic()))
                        except TimeoutError:
                            result = {"error": "timed out"}
                        except Exception as e:  # a failed read is the model's to work around
                            logger.warning(f"loop tool {name} failed: {e}")
                            result = {"error": str(e)[:200]}
                calls.append({"step": step, "tool": name, "args": args, "ms": int((time.monotonic() - c0) * 1000)})
                text = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, default=str)
                if len(text) > RESULT_CAP:
                    text = text[-RESULT_CAP:] + " [cut: earlier part left out]"
                return {"role": "tool", "tool_call_id": call["id"], "content": text}

            messages.extend(await asyncio.gather(*(one(c) for c in wanted)))
        return done(None, max_steps, "steps")

    async def _shorten(self, messages: list[dict], answer: str, max_words: int, deadline: float) -> str | None:
        """An answer too long to say, cut down once by the model that wrote it,
        facts kept. Asked for a word count, a prompt is followed about half the
        time (25 Sep, 12 of 24 over 30 words); a length is a number, so it is
        checked, not hoped for."""
        left = deadline - time.monotonic()
        if left <= 0.3:
            return None
        body = {"model": self.model, "max_tokens": 200, "temperature": 0, "messages": messages + [
            {"role": "assistant", "content": answer},
            {"role": "user", "content": f"That is {len(answer.split())} words; it will be spoken aloud. Say it again "
                                        f"in at most {max_words} words, keeping the facts that answer the question "
                                        "and dropping the rest. Plain spoken words only."}]}
        try:
            r = await self._client.post("/chat/completions", json=body, timeout=left)
            r.raise_for_status()
            record("loop", body, r.json())
            return _clean(r.json()["choices"][0]["message"].get("content")) or None
        except (httpx.HTTPError, ValueError, KeyError) as e:
            logger.warning(f"loop: shortening failed: {e}")
            return None
