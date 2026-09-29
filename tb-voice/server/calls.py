"""Every model call, in full: what was sent and what came back.

One record per call: {"t", "kind", "ms", "request", "response"}. kind is jev
(the gate and intents), brain (the span picker) or loop (the manager's loop).
Nothing is truncated.

Local, the record is calls.jsonl beside the log. Hosted, nothing is written in
the container, which many developers' sessions share: the record goes to this
session's own Mac on its logbox (wire.py), drained in parts behind everything
else (Manager._drain_log), and the app keeps it with the event stream (hf-14).
"""

import json
import os
import time

PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "calls.jsonl")
_f = None


def record(kind: str, request, response, ms: int | None = None, **extra):
    global _f
    rec = {"t": round(time.time(), 3), "kind": kind, "ms": ms, "request": request, "response": response, **extra}
    if os.getenv("TB_HOSTED"):
        from wire import logbox
        box = logbox()
        if box is not None:
            box.put_nowait(rec)
        return rec
    if _f is None:
        _f = open(PATH, "a", buffering=1)
    _f.write(json.dumps(rec, ensure_ascii=False, default=str) + "\n")
    return rec


# A data channel message over 16 KB is not safe to send (docs/wire-v1.md). The
# parts are ASCII (non-ASCII escaped), so 12 000 characters is 12 000 bytes and
# leaves room for the envelope.
PART_CHARS = 12_000


def parts(rec: dict, call_id: str) -> list[dict]:
    """One record as `call` event lines whose texts, joined in order, are the
    record's JSON. tail.py joins them back."""
    text = json.dumps(rec, ensure_ascii=True, default=str)
    chunks = [text[i:i + PART_CHARS] for i in range(0, len(text), PART_CHARS)] or [""]
    return [{"event": "call", "t": rec.get("t"), "kind": rec.get("kind"), "id": call_id,
             "part": i, "parts": len(chunks), "text": c} for i, c in enumerate(chunks)]
