"""The Pipecat LLM service, with every request and streamed response recorded in full."""

import time

from pipecat.services.openai.llm import OpenAILLMService

from calls import record


class RecordedLLMService(OpenAILLMService):
    def build_chat_completion_params(self, params_from_context):
        params = super().build_chat_completion_params(params_from_context)
        self._tb_last_params = params
        return params

    async def get_chat_completions(self, context):
        t0 = time.monotonic()
        stream = await super().get_chat_completions(context)
        params = dict(getattr(self, "_tb_last_params", {}))
        params.pop("stream", None)
        return _Recorded(stream, params, t0)


class _Recorded:
    """Wraps the chunk stream; when it ends, the whole exchange is written."""

    def __init__(self, stream, params, t0):
        self._stream, self._params, self._t0 = stream, params, t0
        self._text, self._reasoning, self._tools = [], [], {}

    def __aiter__(self):
        return self

    async def __anext__(self):
        try:
            chunk = await self._stream.__anext__()
        except StopAsyncIteration:
            self._flush()
            raise
        try:
            d = chunk.choices[0].delta if chunk.choices else None
            if d is not None:
                if d.content:
                    self._text.append(d.content)
                r = getattr(d, "reasoning_content", None) or getattr(d, "reasoning", None)
                if r:
                    self._reasoning.append(r)
                for tc in d.tool_calls or []:
                    slot = self._tools.setdefault(tc.index, {"name": "", "arguments": ""})
                    if tc.function and tc.function.name:
                        slot["name"] += tc.function.name
                    if tc.function and tc.function.arguments:
                        slot["arguments"] += tc.function.arguments
        except Exception:
            pass
        return chunk

    def _flush(self):
        record("llm", self._params, {
            "content": "".join(self._text),
            "reasoning": "".join(self._reasoning),
            "tool_calls": list(self._tools.values()),
        }, ms=int((time.monotonic() - self._t0) * 1000))

    def __getattr__(self, name):
        return getattr(self._stream, name)
