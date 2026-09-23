"""Everything the manager remembers, per session and never per process.

Pipecat Cloud returns an instance to the pool when a session ends and hands it
the next one, and nothing in its docs says module state is reset between them.
It is not: on 22 Sep, 4 of 7 hosted sessions on one Mac opened with a previous
session's turns in the exchange Jev and the brain read, because EXCHANGE,
BOT_VOICE and EXTERNAL_UNTIL were module globals. The turns were a drill's,
started against the production agent; with a second account they would have
been another person's. So the state lives on a Session, bound per session the
way wire.Wire is, and every task the pipeline starts inherits it.
"""

import contextvars
import os
from dataclasses import dataclass, field

from loguru import logger

# How many turns of the exchange the models see at most; see note().
EXCHANGE_KEEP = 12


@dataclass
class Session:
    # The conversation before the text being judged: who said it, what, and
    # whether it was already handled. Every earlier turn is context and only
    # context; a request that was acted on is marked so it is never replayed.
    exchange: list[dict] = field(default_factory=list)
    # Every line noted this session, numbered from 1, so the app can keep the
    # whole record (hf-20); the exchange above is only the tail the models see.
    said: int = 0
    # Whether the manager's own voice is playing, and when it last stopped. The
    # Manager writes it, the echo gate reads it (see mute.py for why the gate
    # does not key on the frames itself).
    bot_voice: dict = field(default_factory=lambda: {"speaking": False, "stopped_at": 0.0})
    # Until when the app is speaking a line in a session's voice; its audio is
    # echo too, and the bot never sees its frames.
    external_until: dict = field(default_factory=lambda: {"t": 0.0})
    # The Notes agent this session types into. Hosted, a file for this lived in
    # the shared container and outlived the account that created it.
    notes_sid: str | None = None


_current: contextvars.ContextVar[Session | None] = contextvars.ContextVar("tb_session", default=None)


def bind() -> Session:
    """A fresh session. Called once at the top of run_bot, before the pipeline
    starts any task, so every task inherits this one."""
    s = Session()
    _current.set(s)
    return s


class Unbound(RuntimeError):
    """Session state read outside a bound session (TB_STRICT_SESSION=1)."""


_warned: set[str] = set()


def unbound(what: str):
    """A read outside run_bot's context. It would get a fresh, empty state and
    forget everything without a word, so it is never quiet: drills set
    TB_STRICT_SESSION=1 and it raises; a live session logs it once per process
    and carries on rather than dropping the user's turn (hf-22)."""
    if os.getenv("TB_STRICT_SESSION"):
        raise Unbound(f"{what} read outside a bound session")
    if what not in _warned:
        _warned.add(what)
        logger.error(f"UNBOUND {what}: read outside a bound session; this task gets empty state")


def current() -> Session:
    s = _current.get()
    if s is None:
        unbound("session")
        s = bind()
    return s
