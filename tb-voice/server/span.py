"""What gets sent is what was said (hf-8).

The composer this replaces asked a model to write the message "from the
developer's words". On 22 Sep it wrote "What message would you like me to send
to the agent?" into an agent, then typed the developer's own request to the
manager into it; on 23 Sep, in a drill, it invented "Run the migration on
staging." from the agent's proposal when nothing had been dictated at all.

Now a model only POINTS. Given the developer's own lines since the manager last
acted, numbered, and the request, it answers with one of:
    {"lines": [from, to]}   a contiguous range of those lines
    {"quote": "..."}        the part of the request that is the message itself
                            ("tell it yes, go ahead"), which must be a literal
                            substring of the request
    {"none": true}          nothing to send yet
and the text sent is copied from the lines or the request, never generated.
Any answer that does not check out is treated as none: the manager keeps
listening rather than sends something unsaid.

Which lines are candidates is decided on types (hf-26): the developer's TALK
and DICTATION lines. A COMMAND line is the developer speaking to the manager and
is never part of a range; its own words reach a send only as a checked quote.
"""

import json
import re
from dataclasses import dataclass

from loguru import logger

import session
from vocab import Line, LineKind, Role

# Lines the developer said that can be part of what is sent.
SENDABLE = {LineKind.TALK, LineKind.DICTATION}
# How far back a send may reach.
MAX_CANDIDATES = 60


@dataclass(frozen=True)
class Candidate:
    n: int
    text: str


@dataclass(frozen=True)
class Pick:
    """Where the message comes from, before any text is copied."""
    lines: tuple[int, int] | None = None
    quote: str | None = None


def from_lines(lines: list[Line]) -> list[Candidate]:
    """This session's exchange since the manager last acted, numbered here."""
    start = 0
    for i, ln in enumerate(lines):
        if ln.kind is LineKind.ACTION:
            start = i + 1
    return [Candidate(n=i + 1, text=ln.text) for i, ln in enumerate(lines[start:], start=start)
            if ln.role is Role.USER and ln.kind in SENDABLE][-MAX_CANDIDATES:]


def from_ledger_rows(rows: list[dict]) -> list[Candidate]:
    """The Mac's ledger since the last action (wire v1 `ledger`), parsed into
    types at this boundary. A row with an unknown role or kind is skipped and
    logged, never guessed."""
    out = []
    for r in rows:
        try:
            role, kind = Role(r.get("role")), LineKind(r.get("kind"))
        except ValueError:
            logger.error(f"span: ledger row with unknown role/kind {r.get('role')!r}/{r.get('kind')!r}; skipped")
            continue
        if role is Role.USER and kind in SENDABLE and isinstance(r.get("n"), int) and r.get("text"):
            out.append(Candidate(n=r["n"], text=r["text"]))
    return out[-MAX_CANDIDATES:]


async def candidates() -> list[Candidate]:
    """The ledger on the Mac when it offers one (every line, across sessions);
    otherwise this session's own exchange."""
    import wire
    if wire.HOSTED:
        r = await wire.call(wire.Tool.LEDGER, {})
        if r is not None and r.get("ok"):
            return from_ledger_rows(r.get("data") or [])
        if r is not None:
            logger.warning(f"span: ledger call failed ({(r.get('error') or {}).get('code')}); using this session's lines")
    return from_lines(session.current().exchange)


def parse_answer(raw: str) -> dict | None:
    """The model's reply, as the one JSON object it was asked for."""
    m = re.search(r"\{.*\}", raw or "", re.S)
    if not m:
        return None
    try:
        obj = json.loads(m.group(0))
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def check(answer: dict | None, cands: list[Candidate], request: str) -> Pick | None:
    """Only an answer that points at real lines, or quotes the request
    exactly, becomes a Pick."""
    if not answer or answer.get("none") is True:
        return None
    if "lines" in answer:
        # [from, to], or every line of the run listed out ([6, 7, 8]): either
        # way, candidate numbers that are one contiguous run of candidates.
        span = answer["lines"]
        numbers = [c.n for c in cands]
        if (isinstance(span, list) and span and all(isinstance(x, int) and x in numbers for x in span)):
            lo, hi = min(span), max(span)
            run = [n for n in numbers if lo <= n <= hi]
            if len(span) <= 2 or sorted(span) == run:
                return Pick(lines=(lo, hi))
        logger.warning(f"span: model pointed at lines {span!r}, which are not one run of candidates; nothing sent")
        return None
    if "quote" in answer:
        q = str(answer["quote"]).strip()
        if q and q in request:
            return Pick(quote=q)
        logger.warning(f"span: model quoted {q[:80]!r}, which is not in the request; nothing sent")
        return None
    return None


def text_of(pick: Pick, cands: list[Candidate]) -> str:
    """The message, copied: the picked lines in order, or the quote."""
    if pick.quote is not None:
        return pick.quote
    lo, hi = pick.lines
    return " ".join(c.text for c in cands if lo <= c.n <= hi).strip()
