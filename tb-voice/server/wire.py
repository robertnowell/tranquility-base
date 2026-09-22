"""The hosted wire: one WebSocket between the app and the bot.

Binary frames are audio, PCM16 mono: 16 kHz up from the app's microphone,
24 kHz down from the synthesizer. Text frames are JSON lines: the same event
lines the app already parses (`events.py`), plus two more shapes that let a
hosted bot use the app's doors, since the bot has no `tbase` and no deep links
where it runs:

    down  {"request":"run","id":"r1","argv":["tbase","targets","--json"]}
    up    {"reply":"r1","code":0,"out":"[...]"}

The app answers a `run` request by doing what `run.sh`'s child would have done
locally (`tbase` subcommands, `open <scheme>://...`), and the bot awaits the
reply. Nothing else changes: the manager's doors are the same calls, routed
through here when TB_HOSTED is set (see tools._run).
"""

import asyncio
import json
import os
import uuid

from loguru import logger
from pipecat.frames.frames import (
    Frame,
    InputAudioRawFrame,
    OutputAudioRawFrame,
    OutputTransportMessageFrame,
    OutputTransportMessageUrgentFrame,
)
from pipecat.serializers.base_serializer import FrameSerializer

HOSTED = bool(os.getenv("TB_HOSTED"))
IN_RATE = 16000

_replies: dict[str, asyncio.Future] = {}
_outbox: asyncio.Queue | None = None


def outbox() -> asyncio.Queue:
    """Lines the bot wants on the wire; the Manager drains this into frames."""
    global _outbox
    if _outbox is None:
        _outbox = asyncio.Queue()
    return _outbox


async def request(kind: str, timeout: float = 45.0, **fields) -> dict:
    """Ask the app to do something and wait for its reply."""
    rid = uuid.uuid4().hex[:8]
    fut = asyncio.get_running_loop().create_future()
    _replies[rid] = fut
    await outbox().put({"request": kind, "id": rid, **fields})
    try:
        return await asyncio.wait_for(fut, timeout)
    except asyncio.TimeoutError:
        return {"code": 124, "out": "timed out"}
    finally:
        _replies.pop(rid, None)


class TBSerializer(FrameSerializer):
    """Audio as bytes, lines as text, replies into the request table."""

    def __init__(self):
        super().__init__(FrameSerializer.InputParams(ignore_rtvi_messages=True))

    async def serialize(self, frame: Frame) -> str | bytes | None:
        if isinstance(frame, OutputAudioRawFrame):
            return bytes(frame.audio)
        if isinstance(frame, (OutputTransportMessageFrame, OutputTransportMessageUrgentFrame)):
            if self.should_ignore_frame(frame):
                return None
            return json.dumps(frame.message, separators=(",", ":"))
        return None

    async def deserialize(self, data: str | bytes) -> Frame | None:
        if isinstance(data, (bytes, bytearray)):
            return InputAudioRawFrame(audio=bytes(data), sample_rate=IN_RATE, num_channels=1)
        try:
            obj = json.loads(data)
        except ValueError:
            logger.warning(f"wire: not JSON: {data[:80]!r}")
            return None
        rid = obj.get("reply")
        if rid and rid in _replies and not _replies[rid].done():
            _replies[rid].set_result(obj)
        return None
