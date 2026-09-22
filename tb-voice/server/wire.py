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
import contextvars
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

class Wire:
    """One session's side of the socket: the lines it wants sent and the
    replies it is waiting for. Per session, never per process: Pipecat Cloud
    keeps a warm process and runs sessions through it back to back, and a
    module-level queue outlived its session. 02:59:42: three sessions' drain
    tasks were all waiting on one queue, so two of every three lines went to a
    dead socket, silently, and a `tbase status` the app never saw timed out
    into "Nobody is waiting"."""

    def __init__(self):
        self.outbox: asyncio.Queue = asyncio.Queue()
        self.replies: dict[str, asyncio.Future] = {}


_current: contextvars.ContextVar[Wire | None] = contextvars.ContextVar("tb_wire", default=None)


def bind() -> Wire:
    """A fresh wire for this session. Called once in bot(); every task the
    pipeline starts inherits it."""
    w = Wire()
    _current.set(w)
    return w


def current() -> Wire:
    w = _current.get()
    if w is None:
        w = bind()
    return w


def outbox() -> asyncio.Queue:
    """Lines the bot wants on the wire; the Manager drains this into frames."""
    return current().outbox


async def request(kind: str, timeout: float = 45.0, **fields) -> dict:
    """Ask the app to do something and wait for its reply."""
    w = current()
    rid = uuid.uuid4().hex[:8]
    fut = asyncio.get_running_loop().create_future()
    w.replies[rid] = fut
    await w.outbox.put({"request": kind, "id": rid, **fields})
    try:
        return await asyncio.wait_for(fut, timeout)
    except asyncio.TimeoutError:
        logger.warning(f"wire: no reply to {kind} {rid} in {timeout:.0f}s")
        return {"code": 124, "out": "timed out"}
    finally:
        w.replies.pop(rid, None)


def take_reply(obj: dict, wire: "Wire | None" = None) -> bool:
    """Hand a reply to whoever is waiting for it. The WebSocket serializer and
    the WebRTC data channel both land here, so the shapes are identical on
    either transport and only the carriage differs."""
    w = wire or current()
    rid = obj.get("reply")
    fut = w.replies.get(rid) if rid else None
    if fut is not None and not fut.done():
        fut.set_result(obj)
        return True
    return False


class TBSerializer(FrameSerializer):
    """Audio as bytes, lines as text, replies into the request table."""

    def __init__(self, wire: Wire | None = None):
        super().__init__(FrameSerializer.InputParams(ignore_rtvi_messages=True))
        self._wire = wire or current()

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
        take_reply(obj, self._wire)
        return None
