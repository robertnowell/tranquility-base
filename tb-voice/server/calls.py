"""Every model call, in full: what was sent and what came back.

One record per call: {"t", "kind", "ms", "request", "response"}. kind is jev
(the gate and intents), brain (the span picker) or loop (the manager's loop).
Nothing is truncated, and nothing is written where the bot runs, which many
developers' sessions share: the record goes to this session's own Mac on its
logbox (wire.py), drained in parts behind everything else
(Manager._drain_log), and the app keeps it with the event stream (hf-14).
"""

import json
import time


def record(kind: str, request, response, ms: int | None = None, **extra):
    from wire import logbox
    rec = {"t": round(time.time(), 3), "kind": kind, "ms": ms, "request": request, "response": response, **extra}
    box = logbox()
    if box is not None:
        box.put_nowait(rec)
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
