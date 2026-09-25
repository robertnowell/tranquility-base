"""The doors to the Mac: `_run` runs a `tbase` read (over wire v1 when this Mac
offers it) or a verb the app runs. The model tools that used to live here went
with Pipecat's LLM stage (hf-6); the manager's loop has its own (loop.py)."""

import asyncio
import json
import os

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
        # Wire v1 first, for the reads it covers; an app without it (Prod can
        # lag Dev by a release) still answers request:run (hf-3).
        v1 = _as_call(argv)
        if v1 is not None:
            r = await wire.call(*v1)
            if r is not None:
                if r.get("ok"):
                    return 0, json.dumps(r.get("data"))
                err = r.get("error") or {}
                return (124 if err.get("code") == "timeout" else 1), f"{err.get('code')}: {err.get('message')}"
        # No tbase and no deep links where the bot runs: the app does it and replies.
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


def _as_call(argv) -> tuple[wire.Tool, dict] | None:
    """The v1 tool for a tbase read, or None to keep request:run. The argv is
    built in this file's own callers, so this is a table of our own calls, not
    a reading of anything a person said."""
    if argv[0] != TBASE:
        return None
    rest = tuple(argv[1:])
    if rest == ("targets", "--json"):
        return wire.Tool.AGENTS, {}
    if rest == ("status", "--json"):
        return wire.Tool.WAITING, {}
    if len(rest) == 3 and rest[0] == "brief" and rest[2] == "--json":
        return wire.Tool.BRIEF, {"agent": rest[1]}
    return None


def _json_or_text(code: int, out: str):
    try:
        return {"exit": code, "data": json.loads(out)}
    except Exception:
        return {"exit": code, "text": out[-2000:]}
