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

Which lines are candidates is decided on types (hf-26): every line the
developer said, including a COMMAND -- one they said to the manager -- which is
marked as such so the model can tell it apart.

COMMAND lines were excluded until 29 Sep, on the reasoning that words said to
the manager are not words for an agent, and that a developer who wants them
sent will say them again inside the request. Measured, that reasoning cost a
message. The ledger of 17:01:

  [13] talk     Oh, can we start?
  [14] command  And is this going to be deterministic per run or non-deterministic?
  [16] spoken   The record does not say.
  [17] command  You know, send that message, everything I just said, to the agent.

Line 14 is the message. The gate heard it as addressed to the manager, which it
was -- he asked it out loud and the manager answered -- and that verdict took
the line out of the candidate list, so the picker was shown three fragments
("Okay, let's", "Let's see. We want to say.", "Oh, can we start?"), answered
{"none": true}, and was right to. Nothing was sent and, until #688, nothing
said so.

A line being addressed to the manager is not evidence about whom it is FOR. So
every line is a candidate now, the ones said to the manager are marked, and the
model is told that a line which only directs the send is never the message. The
request's own line is dropped outright: it is given separately, and pointing at
it is how the manager comes to type "send that to the agent" into an agent.
"""

import json
import re
from dataclasses import dataclass

from loguru import logger

import session
from vocab import Line, LineKind, Role

# Lines the developer said that can be part of what is sent. A COMMAND is in
# here and marked, never dropped: see the docstring, 29 Sep 17:01.
SENDABLE = {LineKind.TALK, LineKind.DICTATION, LineKind.COMMAND}
# How far back a send may reach.
MAX_CANDIDATES = 60


@dataclass(frozen=True)
class Candidate:
    n: int
    text: str
    to_manager: bool = False   # they said this line to the manager (a COMMAND)


def numbered(cands: list[Candidate]) -> str:
    """The candidate lines as the model is shown them, in one place so the
    picker and the loop cannot be shown different lists."""
    return "\n".join(f"[{c.n}] " + ("(said to you) " if c.to_manager else "") + c.text
                      for c in cands) or "(none)"


def _same_utterance(a: str, b: str) -> bool:
    """One spoken line and another, compared as the transcriber gave them:
    case, spacing and punctuation do not distinguish two utterances."""
    def key(t: str) -> str:
        return re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()
    return bool(key(a)) and key(a) == key(b)


@dataclass(frozen=True)
class Pick:
    """Where the message comes from, before any text is copied."""
    lines: tuple[int, int] | None = None
    quote: str | None = None


def from_lines(lines: list[Line], request: str = "") -> list[Candidate]:
    """This session's exchange since the manager last acted, numbered here."""
    start = 0
    for i, ln in enumerate(lines):
        if ln.kind is LineKind.ACTION:
            start = i + 1
    out = [Candidate(n=i + 1, text=ln.text, to_manager=ln.kind is LineKind.COMMAND)
           for i, ln in enumerate(lines[start:], start=start)
           if ln.role is Role.USER and ln.kind in SENDABLE]
    return _without_the_request(out, request)[-MAX_CANDIDATES:]


def _without_the_request(cands: list[Candidate], request: str) -> list[Candidate]:
    """The line that IS the request is not a candidate. It is given to the model
    on its own, and a model that points at it makes the manager type "send that
    to the agent" into an agent."""
    if not request:
        return cands
    return [c for c in cands if not _same_utterance(c.text, request)]


def from_ledger_rows(rows: list[dict], request: str = "") -> list[Candidate]:
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
            out.append(Candidate(n=r["n"], text=r["text"], to_manager=kind is LineKind.COMMAND))
    return _without_the_request(out, request)[-MAX_CANDIDATES:]


async def candidates(request: str = "") -> list[Candidate]:
    """The ledger on the Mac when it offers one (every line, across sessions);
    otherwise this session's own exchange. The request's own line is left out."""
    import wire
    r = await wire.call(wire.Tool.LEDGER, {})
    if r is not None and r.get("ok"):
        return from_ledger_rows(r.get("data") or [], request)
    if r is not None:
        logger.warning(f"span: ledger call failed ({(r.get('error') or {}).get('code')}); using this session's lines")
    return from_lines(session.current().exchange, request)


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
