"""One JSON line per event, on stdout, for whoever hosts the bot.

Today that is a person reading the log and the Pipecat playground (the same event is also
pushed as an RTVI server message so the playground's events panel shows it). Tomorrow it is
the Swift app, which spawns the bot as a stdio child and paints the orb from these lines.
Events: listening, addressed, speaking, stage, earcon, tool.
"""

import json
import os
import sys
import time

from pipecat.processors.frameworks.rtvi import RTVIServerMessageFrame

_sink = None


def _out():
    """stdout, or the FIFO the host names in TB_EVENTS (see run.sh)."""
    global _sink
    if _sink is None:
        path = os.getenv("TB_EVENTS")
        _sink = open(path, "a", buffering=1) if path else sys.stdout
    return _sink


_file = None


def line(event: str, **fields) -> dict:
    global _file
    rec = {"event": event, "t": round(time.time(), 3), **fields}
    text = json.dumps(rec, separators=(",", ":")) + "\n"
    global _sink
    try:
        out = _out()
        out.write(text)
        out.flush()
    except (BrokenPipeError, OSError) as err:
        # The host went away (an app relaunch orphans its child). Keep the file
        # stream; never let a dead pipe fail a turn.
        if _sink is not sys.stderr:
            sys.stderr.write(f"events: host pipe gone ({err}); file only from here\n")
        _sink = sys.stderr
    # And always to events.jsonl beside the log, so `tail -f` shows the stream
    # whether the app, the playground, or nobody is listening.
    if os.getenv("TB_HOSTED"):
        return rec  # nothing on disk where the bot is hosted
    if _file is None:
        _file = open(os.path.join(os.path.dirname(__file__), "events.jsonl"), "a", buffering=1)
    _file.write(text)
    return rec


async def emit(processor, event: str, **fields):
    """Write the line and, if a processor is given, mirror it to the playground.
    Hosted, the line also goes on the wire for the app (wire.outbox)."""
    rec = line(event, **fields)
    if os.getenv("TB_HOSTED"):
        from wire import outbox
        await outbox().put(rec)
    elif processor is not None:
        await processor.push_frame(RTVIServerMessageFrame(data={"tb": rec}))
    return rec
