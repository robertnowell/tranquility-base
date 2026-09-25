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
import time
import uuid
from enum import Enum

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
        # Wire v1 (hf-3, docs/wire-v1.md): the tools the Mac said it offers in
        # its hello, and the calls waiting on a result. None until a hello
        # arrives; an app that never sends one stays on request:run.
        self.tools: set[Tool] | None = None
        self.hello_seen = asyncio.Event()
        self.calls: dict[str, asyncio.Future] = {}
        self.mac_events: asyncio.Queue = asyncio.Queue()
        self.born = time.monotonic()


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
        from session import unbound
        unbound("wire")  # a fresh queue here is a dead socket; see session.unbound
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


# How long each v1 tool may take; the Mac enforces its own and this side gives
# up half a second after it (docs/wire-v1.md).
class WireKind(Enum):
    """The `wire` field of a v1 frame (docs/wire-v1.md)."""
    HELLO = "hello"
    CALL = "call"
    RESULT = "result"
    CANCEL = "cancel"
    EVENT = "event"


class Tool(Enum):
    """The tools a Mac may offer in its hello. A name the bot does not know is
    logged and ignored at the hello; nothing downstream sees it as a string."""
    AGENTS = "agents"
    WAITING = "waiting"
    BRIEF = "brief"
    TRANSCRIPT = "transcript"
    LEDGER = "ledger"
    SEND = "send"


HELLO_GRACE_S = 1.5
DEADLINES_MS = {Tool.AGENTS: 3000, Tool.WAITING: 3000, Tool.BRIEF: 3000, Tool.TRANSCRIPT: 5000, Tool.LEDGER: 2000,
                # The app's Send types, then watches the agent take it.
                Tool.SEND: 20000}


async def call(tool: Tool, args: dict | None = None, deadline_ms: int | None = None,
               idem: str | None = None) -> dict | None:
    """Wire v1: ask the Mac for one named tool. Returns the result frame
    ({ok, data} or {ok: false, error}), or None when this Mac does not offer
    the tool, so the caller keeps the request:run path for older apps."""
    w = current()
    if w.tools is None:
        # The hello rides the same socket as the first audio: a call made in
        # the session's first breath waits for it, up to 1.5 s after the
        # session began. Later, no hello means an app without v1, and waiting
        # would only add 1.5 s to every one of its reads.
        remaining = HELLO_GRACE_S - (time.monotonic() - w.born)
        if remaining <= 0:
            return None
        try:
            await asyncio.wait_for(w.hello_seen.wait(), remaining)
        except TimeoutError:
            return None
    if tool not in (w.tools or set()):
        return None
    cid = uuid.uuid4().hex[:8]
    deadline_ms = deadline_ms or DEADLINES_MS.get(tool, 5000)
    fut = asyncio.get_running_loop().create_future()
    w.calls[cid] = fut
    frame = {"wire": WireKind.CALL.value, "id": cid, "tool": tool.value, "args": args or {},
             "deadline_ms": deadline_ms}
    if idem:
        frame["idem"] = idem
    await w.outbox.put(frame)
    try:
        return await asyncio.wait_for(fut, deadline_ms / 1000 + 0.5)
    except TimeoutError:
        logger.warning(f"wire: no result for {tool.value} {cid} in {deadline_ms} ms")
        await w.outbox.put({"wire": WireKind.CANCEL.value, "id": cid})
        return {"ok": False, "error": {"code": "timeout", "message": f"{tool.value} gave no result", "retryable": not idem}}
    finally:
        w.calls.pop(cid, None)


def _take_wire(obj: dict, w: "Wire") -> bool:
    try:
        kind = WireKind(obj.get("wire"))
    except ValueError:
        logger.error(f"wire: UNKNOWN frame kind {obj.get('wire')!r} from the Mac; ignored")
        return True
    if kind is WireKind.HELLO:
        offered = set()
        for t in obj.get("tools") or []:
            name = t.get("name") if isinstance(t, dict) else None
            try:
                offered.add(Tool(name))
            except ValueError:
                logger.warning(f"wire: the Mac offers {name!r}, which this bot does not know; ignored")
        w.tools = offered
        w.hello_seen.set()
        logger.info(f"wire: hello, protocol {obj.get('protocol')}, app {obj.get('app_version')}, "
                    f"tools {sorted(t.value for t in offered)}")
    elif kind is WireKind.RESULT:
        fut = w.calls.get(obj.get("id"))
        if fut is not None and not fut.done():
            fut.set_result(obj)
    elif kind is WireKind.EVENT:
        w.mac_events.put_nowait(obj)  # chords and tray changes; read by later work (hf-16, hf-12)
    else:
        logger.error(f"wire: a {kind.value} frame arrived from the Mac, which only the bot sends; ignored")
    return True


def take_reply(obj: dict, wire: "Wire | None" = None) -> bool:
    """Hand a reply to whoever is waiting for it. The WebSocket serializer and
    the WebRTC data channel both land here, so the shapes are identical on
    either transport and only the carriage differs."""
    w = wire or current()
    if "wire" in obj:
        return _take_wire(obj, w)
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
