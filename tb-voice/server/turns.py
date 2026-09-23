"""Turns are decided one at a time, in the order they were said.

Every finished turn used to start its own detached task, so a second turn was
judged while the first was still being handled. Speech in the gap between "send
a message to Mailchimp" and the open message it creates went through the
command gate instead of into the message, and two dictated fragments could
append out of order. Now each turn joins one queue per session and one worker
takes them in order. What a turn IS (dictation, or something to judge) is
decided when the worker reaches it, after everything said before it has
finished, never when it arrives (hf-13).

The worker is still detached from the frame that carried the turn: an
interruption cancels a frame's task, and an invite that died between
"Inviting…" and the hear verb once left nobody speaking (16:49:39).
"""

import asyncio
from collections.abc import Awaitable, Callable

from loguru import logger


class TurnQueue:
    def __init__(self, handle: Callable[[tuple], Awaitable[None]]):
        self._q: asyncio.Queue = asyncio.Queue()
        self._handle = handle
        self.busy = False

    def put(self, turn: tuple):
        self._q.put_nowait(turn)

    def waiting(self) -> int:
        return self._q.qsize()

    async def run(self):
        while True:
            turn = await self._q.get()
            self.busy = True
            try:
                await self._handle(turn)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # one bad turn never stops the ones behind it
                logger.exception(f"turn failed: {e}")
            finally:
                self.busy = False
                self._q.task_done()

    async def drained(self):
        """Every turn put so far has been handled (for drills)."""
        await self._q.join()
