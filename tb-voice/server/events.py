"""One JSON line per event: to this session's Mac, and to the bot's own log.

The line goes on the wire (wire.outbox), and the app paints the orb from it and
keeps it in manager-events.jsonl. It is also printed, which is the host's log.
Events: listening, addressed, speaking, stage, earcon, tool, and the rest in
ManagerEvent (TranquilityCore/ManagerMode.swift).
"""

import json
import sys
import time


def line(event: str, **fields) -> dict:
    rec = {"event": event, "t": round(time.time(), 3), **fields}
    try:
        sys.stdout.write(json.dumps(rec, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, OSError):
        pass  # never let a dead log fail a turn
    return rec


async def emit(processor, event: str, **fields):
    """Write the line and put it on the wire for the app (wire.outbox)."""
    from wire import outbox
    rec = line(event, **fields)
    await outbox().put(rec)
    return rec
