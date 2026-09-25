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

A turn can be cut (hf-25): talking over the manager, or telling it to stop
while it thinks, ends the turn in flight instead of queueing behind it. What a
cut can never do is stop half an act: anything that changes the world outside
this process runs through `effect`, which finishes once started. A stop during
the span pick means nothing is sent; a stop once the send has begun ends only
the talking about it.
"""

import asyncio
from collections.abc import Awaitable, Callable

from loguru import logger


class TurnQueue:
    def __init__(self, handle: Callable[[tuple], Awaitable[None]]):
        self._q: asyncio.Queue = asyncio.Queue()
        self._handle = handle
        self.busy = False
        self._current: asyncio.Task | None = None

    def put(self, turn: tuple):
        self._q.put_nowait(turn)

    def waiting(self) -> int:
        return self._q.qsize()

    async def run(self):
        while True:
            turn = await self._q.get()
            self.busy = True
            # Its own task, so a cut ends this turn and not the worker.
            self._current = task = asyncio.create_task(self._handle(turn))
            try:
                await asyncio.wait({task})
                if not task.cancelled() and task.exception():
                    # one bad turn never stops the ones behind it
                    logger.opt(exception=task.exception()).error(f"turn failed: {task.exception()}")
            except asyncio.CancelledError:
                task.cancel()
                raise
            finally:
                self._current = None
                self.busy = False
                self._q.task_done()

    def cut(self, why: str) -> bool:
        """End the turn in flight, if there is one. Its acts already begun
        finish (`effect`); its thinking and its talking do not."""
        task = self._current
        if task is None or task.done():
            return False
        logger.info(f"turn cut: {why}")
        task.cancel()
        return True

    async def drained(self):
        """Every turn put so far has been handled (for drills)."""
        await self._q.join()


async def effect(aw: Awaitable):
    """An act on the world (a send, a new agent, a verb the app runs): once
    begun it finishes, even when the turn that began it is cut."""
    return await asyncio.shield(aw)
