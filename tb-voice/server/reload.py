"""Reload when the source changes: exit 75, which the app reads as "start me
again". Only in hosted mode; the playground runner has its own life."""

import asyncio
import os
import sys

from loguru import logger

HERE = os.path.dirname(os.path.abspath(__file__))
WATCH = ("bot.py", "manager.py", "tools.py", "prompt.py", "spoken.py", "tts.py", "events.py", "mute.py", "llm.py", "calls.py", ".env")


def _stamp():
    out = {}
    for f in WATCH:
        p = os.path.join(HERE, f)
        try:
            out[f] = os.stat(p).st_mtime_ns
        except FileNotFoundError:
            out[f] = None
    return out


async def watch(on_change):
    base = _stamp()
    while True:
        await asyncio.sleep(1.0)
        now = _stamp()
        changed = [f for f in WATCH if now.get(f) != base.get(f)]
        if changed:
            logger.info(f"reload: {', '.join(changed)} changed; exiting 75 for the host")
            await on_change(changed)
            os._exit(75)
