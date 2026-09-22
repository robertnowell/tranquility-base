"""Every model call, in full: what was sent and what came back.

calls.jsonl beside the log, one record per call: {"t", "kind", "ms", "request", "response"}.
kind is jev (the gate and intents), brain (a question about the session on stage),
llm (the tool-calling turn through Pipecat). Nothing is truncated; this file is the
record of what the manager was told and said, and the viewer shows it.
"""

import json
import os
import time

PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "calls.jsonl")
_f = None


def record(kind: str, request, response, ms: int | None = None, **extra):
    global _f
    if _f is None:
        _f = open(PATH, "a", buffering=1)
    rec = {"t": round(time.time(), 3), "kind": kind, "ms": ms, "request": request, "response": response, **extra}
    _f.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
    return rec
