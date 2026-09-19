"""One JSON line per event, on stdout, for whoever hosts the bot.

Today that is a person reading the log and the Pipecat playground (the same event is also
pushed as an RTVI server message so the playground's events panel shows it). Tomorrow it is
the Swift app, which spawns the bot as a stdio child and paints the orb from these lines.
Events: listening, addressed, speaking, stage, earcon, tool.
"""

import json
import sys
import time

from pipecat.processors.frameworks.rtvi import RTVIServerMessageFrame


def line(event: str, **fields) -> dict:
    rec = {"event": event, "t": round(time.time(), 3), **fields}
    sys.stdout.write(json.dumps(rec, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    return rec


async def emit(processor, event: str, **fields):
    """Write the line and, if a processor is given, mirror it to the playground."""
    rec = line(event, **fields)
    if processor is not None:
        await processor.push_frame(RTVIServerMessageFrame(data={"tb": rec}))
    return rec
