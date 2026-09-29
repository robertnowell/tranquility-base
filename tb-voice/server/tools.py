"""The doors to the Mac: `_run` asks for one of this bot's own `tbase` calls or
an `open`, by the wire v1 tool that does it. The model tools that used to live here went
with Pipecat's LLM stage (hf-6); the manager's loop has its own (loop.py)."""

import asyncio
import json
import os
import uuid

from loguru import logger

import wire
from events import line
from wire import HOSTED

TBASE = os.getenv("TBASE_BIN", "tbase")
SCHEME = os.getenv("TB_URL_SCHEME", "tranquilitybase")


async def _run(*argv: str, timeout: float = 45.0) -> tuple[int, str]:
    logger.info("exec " + " ".join(argv))
    line("tool", argv=list(argv))
    if HOSTED:
        # Every door by name (hf-6, one door): the Mac runs only the tools it
        # offers, and no longer any argv it is sent. An app from before this
        # release offers fewer, and still answers request:run for the rest;
        # that fallback goes once the Prod release offers them all.
        v1 = _as_call(argv)
        if v1 is not None:
            tool, args = v1
            idem = uuid.uuid4().hex if tool in wire.EFFECTS else None
            r = await wire.call(tool, args, idem=idem)
            if r is not None:
                return _answer(r)
        name = "tbase" if argv[0] == TBASE else argv[0]
        r = await wire.request("run", timeout=timeout, argv=[name, *argv[1:]])
        return int(r.get("code", 1)), str(r.get("out", ""))
    p = await asyncio.create_subprocess_exec(
        *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT
    )
    try:
        out, _ = await asyncio.wait_for(p.communicate(), timeout)
    except TimeoutError:
        p.kill()
        return 124, "timed out"
    return p.returncode or 0, out.decode(errors="replace")


def _answer(r: dict) -> tuple[int, str]:
    """A result frame as the (exit, output) every caller reads. A CLI effect
    answers {exit, out}, exactly what request:run returned; a read answers its
    JSON. A timed-out effect may have happened, so it reads as the CLI's own
    timeout and is never retried (docs/wire-v1.md)."""
    if not r.get("ok"):
        err = r.get("error") or {}
        return (124 if err.get("code") == "timeout" else 1), f"{err.get('code')}: {err.get('message')}"
    data = r.get("data")
    if isinstance(data, dict) and isinstance(data.get("exit"), int) and isinstance(data.get("out"), str):
        return data["exit"], data["out"]
    return 0, json.dumps(data)


def _as_call(argv) -> tuple[wire.Tool, dict] | None:
    """The v1 tool for one of this bot's own doors, or None for one that has
    none. The argv is built in this package's own callers, so this is a table
    of our own calls, not a reading of anything a person said."""
    if argv[0] == "open" and len(argv) == 2:
        return wire.Tool.OPEN, {"url": argv[1]}
    if argv[0] != TBASE:
        return None
    rest = tuple(argv[1:])
    if rest == ("targets", "--json"):
        return wire.Tool.AGENTS, {}
    if rest == ("status", "--json"):
        return wire.Tool.WAITING, {}
    if len(rest) == 3 and rest[0] == "brief" and rest[2] == "--json":
        return wire.Tool.BRIEF, {"agent": rest[1]}
    if len(rest) == 3 and rest[0] == "voice" and rest[2] == "--json":
        return wire.Tool.VOICE, {"agent": rest[1]}
    if rest in (("new",), ("new", "--codex")):
        return wire.Tool.START_AGENT, {"harness": "codex" if "--codex" in rest else "claude"}
    if len(rest) == 2 and rest[0] == "enroll":
        return wire.Tool.ENROLL, {"agent": rest[1]}
    if len(rest) == 3 and rest[0] == "send":
        return wire.Tool.QUIET_SEND, {"agent": rest[1], "text": rest[2]}
    return None


def _json_or_text(code: int, out: str):
    try:
        return {"exit": code, "data": json.loads(out)}
    except Exception:
        return {"exit": code, "text": out[-2000:]}
