"""The manager: silence by default, one Jev call per turn, one agent on stage.

Every finished user turn arrives as an LLMContextFrame (the aggregator has already
appended the words to the context). One request to Jev answers two questions at once:
was the manager addressed, and which intent. Most intents are handled here without the
LLM: inviting a session to speak, reading a rung, saying nothing. The LLM runs only for
custom questions, summaries, sends and starts, with the stage handed to it as a note.
See docs/design.md sections 2, 6, 7 and the manager-mode architecture page.
"""

import asyncio
import json
import os
import re
import time
import uuid

import httpx
from loguru import logger
from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    EndWorkerFrame,
    Frame,
    InputTransportMessageFrame,
    InterruptionFrame,
    LLMContextFrame,
    StartFrame,
    TTSSpeakFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from calls import record
import build_stamp
from events import emit, line
import session
import span
from vocab import Intent, Line, LineKind, Role, parse_intent
from turns import TurnQueue, effect
from loop import Loop, Tool
from spoken import spoken
from tools import TBASE, _json_or_text, _run

JEV_URL = "https://api.typesafe.ai/v1/systemone"
NAME = os.getenv("TB_MANAGER_NAME", "Tranquility")
THRESHOLD = float(os.getenv("TB_ADDRESSED_THRESHOLD", "0.5"))
HOLD_SECS = float(os.getenv("TB_HOLD_SECS", "1.2"))
HOLD_NAMED_SECS = float(os.getenv("TB_HOLD_NAMED_SECS", "2.5"))
# The same command twice inside this window is one sentence heard as two, not a
# person asking twice. A person who means it says it again after the answer.
REPEAT_SECS = float(os.getenv("TB_REPEAT_SECS", "2.5"))
# Hosted: a session nobody has spoken to for this long ends itself. Every
# minute a session is up is a billed minute (Cloud, the transcriber), and
# hands-free left on overnight would otherwise run to the 4 h cap. The app
# hears the `idle` line and says so; a chord starts a fresh session.
IDLE_SECS = float(os.getenv("TB_IDLE_SECS", "1200"))
# Hosted: Cloud caps a session at four hours. A little before that, at a
# moment with nothing open, the bot ends the session with a `rotate` line and
# the app opens a fresh one. The bot decides because only it knows whether a
# message is open; the app's microphone level cannot tell a pause between
# sentences from silence.
SESSION_LIFE_SECS = float(os.getenv("TB_SESSION_LIFE_SECS", str(3 * 3600 + 55 * 60)))
SCHEME = os.getenv("TB_URL_SCHEME", "tranquilitybase")

INTENTS: dict[Intent, str] = {
    Intent.INVITE_NEXT: "Invite the next agent or session to speak; 'next agent'; 'who is up'; 'what's next' when no agent is on stage",
    Intent.RUNG_GOAL: "Asks what this project or piece of work is, or what the goal is",
    Intent.RUNG_FINDINGS: "Asks what the agent found or what happened",
    Intent.RUNG_SOLUTION: "Asks for the recommended next step, the solution, or what it proposes",
    Intent.RUNG_WHY: "Asks why, for the rationale or reasoning",
    Intent.CUSTOM: "Any other question about the agent on stage or its work: files, code, status, details, opinions",
    Intent.SEND_MESSAGE: ("Asks the assistant to send, tell, pass on or relay a message to an agent, "
                          "the notes agent included"),
    Intent.READ_BACK: ("Asks what the assistant would send, or to read a message back before it goes: "
                       "a dry run, nothing is sent"),
    Intent.START_AGENT: "Asks to start, spin up, or open a new agent or session",
    Intent.SUMMARIZE_RECENT: "Asks what has been going on recently across ALL agents, or what we did today or yesterday; not about one session",
    Intent.TEACH: "Asks what the manager can do, what this is, who it is, or how it works",
    Intent.FLEET_STATUS: "Asks which agents or sessions are live or waiting on the developer, or to see or list them",
    Intent.SPEAK: "Tells the manager to say something, speak, respond, answer, or prove it is listening",
    Intent.MUTE: "Tells whoever is talking to stop, pause, be quiet, mute, hold on, or that's enough",
    Intent.NONE: "Addressed but nothing to do: an acknowledgement, a compliment, or filler",
}

# How the transcriber has actually spelled the name, from bot.log. A word that
# starts like one of these, at the start of a turn, is the name; the gate does
# not get to disagree with the person saying it.
NAME_SOUNDS = ("tranq", "trank", "drink", "tranc", "trinq", "tranguil", "tranqu")

# The words of the request, not of a name. "Can you invite the next speaker?"
# is entirely made of these, and an agent that happened to be called "Next
# Steps" must not win it. Four characters and up, because `_named_session`
# has already dropped anything shorter; every word here was said by Robert in
# an actual invite on 27 Sep, or is the manager's own name.
ASKING_WORDS = {
    "invite", "next", "agent", "agents", "speaker", "session", "sessions",
    "please", "could", "would", "should", "bring", "speak", "talk", "tell",
    "show", "that", "this", "them", "they", "then", "from", "with", "what",
    "whos", "who's", "have", "here", "hear", "thanks", "thank", "okay",
    "tranquility", "tranquility's", "base", "another", "other", "again",
    "someone", "somebody", "anyone", "anybody", "person", "people", "up",
}


def only_the_name(text: str) -> bool:
    """The whole fragment is the manager's name and nothing else. 13:09, 22 Sep:
    "Tranquility." arrived as its own final, was judged alone, and then "Can you
    tell me about your capabilities?" was judged again a second later: two
    verdicts, two answers, from one sentence. A name on its own is never a
    command, whatever punctuation the transcriber put after it."""
    words = [w.strip(",.!?;:").lower() for w in text.split()]
    return len(words) == 1 and words[0].startswith(NAME_SOUNDS)


class DoorRefused(RuntimeError):
    """A read door answered, and the answer was no."""


def _rows(code: int, out: str, what: str, pick) -> list[dict]:
    """Rows, or an exception. Never an empty list standing in for a failure.

    28 Sep: `tbase status --json` came to 29,160 bytes, the data channel
    refuses anything over 16,384, and the app said so plainly --
    `{'ok': False, 'error': {'code': 'too_large', ...}}`. This read that
    refusal, found no list in it, and returned `[]`. So the manager told
    Robert "Nobody is waiting on you" while his grid showed a column of
    green, and nothing anywhere said a door had been refused.

    An empty list is a real answer -- it means the queue is empty -- and it
    must not also be how a failure arrives. Anything that is not rows raises,
    `_handle_turn` reports it with a reason, and the manager says something
    true instead of something confidently wrong."""
    answer = _json_or_text(code, out)
    rows = pick(answer.get("data"))
    if code != 0 or rows is None:
        detail = (answer.get("text") or str(answer.get("data")))[:120]
        raise DoorRefused(f"could not read {what}: {detail}")
    return rows


def _why(e: BaseException) -> str:
    """A reason a person can read, which `str(e)` is often not.

    28 Sep: every `error` event in the viewer read `reason: ""`. The exception
    was `httpx.ReadTimeout`, and httpx raises it wrapping a bare `TimeoutError`
    whose message is the empty string -- so the panel showed the word "error"
    and nothing else, four times in a row, while the manager appeared simply
    broken. An exception class always has a name even when it has nothing to
    say, and the name is what tells you it was the gate and not the fleet."""
    text = str(e).strip()
    name = type(e).__name__
    return (f"{name}: {text}" if text else name)[:160]


def names_the_manager(text: str) -> bool:
    """The vocative: the FIRST word sounds like the name and is not 'tranquility
    base' the product. 'Drinkody, can you…' yes; 'let me drink…' no."""
    words = [w.strip(",.!?;:").lower() for w in text.split()[:2]]
    if not words or not words[0].startswith(NAME_SOUNDS):
        return False
    return len(words) < 2 or words[1] != "base"


# Intents that take seconds (a tool run, a model call) before anything is heard.
SLOW_INTENTS = {Intent.SEND_MESSAGE, Intent.READ_BACK, Intent.SUMMARIZE_RECENT, Intent.CUSTOM, Intent.SPEAK}

class JevClient:
    def __init__(self, api_key: str):
        # Measured inside the bot, 28 Sep, 70 successful gate calls:
        # p50 102ms, p90 132ms, p99 153ms, max 153ms, none over a second.
        # And 4 calls that never answered at all, at the 8s ceiling.
        #
        # Nothing in between. A distribution with nothing between 153ms and
        # 8000ms is not a slow server -- a slow server has a tail. It is a
        # request that was never answered, and the traceback says why:
        # `AsyncHTTP11Connection [... CLOSED, Request Count: 1]`. httpx took a
        # pooled connection the server had already hung up on and wrote to it.
        # HTTP/1.1 cannot detect that before writing; the race is in the
        # protocol, not in anybody's code.
        #
        # So: a voice-sized budget, because a spoken turn cannot wait eight
        # seconds for permission to exist. 1.5s is ten times the measured p99.
        # `keepalive_expiry` is the structural half -- retiring idle sockets on
        # our own schedule means the pool has far fewer chances to hand out a
        # dead one. Neither is a guess; both come off the numbers above.
        self._headers = {"Authorization": f"Bearer {api_key}"}
        self._client = httpx.AsyncClient(
            headers=self._headers,
            timeout=httpx.Timeout(1.5, connect=2.0),
            limits=httpx.Limits(keepalive_expiry=5.0))

    last: dict = {}

    async def ask(self, state: dict, questions: dict) -> dict:
        t0 = time.monotonic()
        r = await self._post({"state": state, "model": "jev-latest", "questions": questions})
        r.raise_for_status()
        answers = r.json()["answers"]
        ms = int((time.monotonic() - t0) * 1000)
        self.last = {"state": state, "questions": list(questions), "answers": answers, "ms": ms}
        record("jev", {"state": state, "model": "jev-latest", "questions": questions}, r.json(), ms=ms)
        return answers

    async def _post(self, body: dict) -> httpx.Response:
        """One retry, and only for the failure that earns it.

        A timeout here means a dead pooled socket, not a slow gate (the
        measurements above have nothing between 153ms and the ceiling). A dead
        socket is discovered by writing to it, so the first attempt IS the
        detection and there is nothing to do but write again -- on a connection
        that cannot be the same one, because this closes the pool first.

        Only on timeout, and only once. A 500 is the gate disagreeing with us
        and saying it twice will not help; two attempts at 1.5s still fit
        inside a turn a person will wait through, and a third would not."""
        try:
            return await self._client.post(JEV_URL, json=body)
        except httpx.TimeoutException:
            logger.warning("gate: no answer in 1.5s; retrying on a fresh connection")
            await self._client.aclose()
            self._client = httpx.AsyncClient(
                headers=self._headers,
                timeout=httpx.Timeout(1.5, connect=2.0),
                limits=httpx.Limits(keepalive_expiry=5.0))
            return await self._client.post(JEV_URL, json=body)

    async def turn(self, utterance: str, recent: list[str], stage: dict | None):
        before = [{"who": ln.jev_who, "status": ln.jev_status, "text": ln.jev_text}
                  for ln in session.current().exchange[-8:]]
        answers = await self.ask(*self.turn_request(utterance, before, stage))
        return float(answers["addressed"]["noul"]), answers["intent"]

    @staticmethod
    def turn_request(utterance: str, before: list[dict], stage: dict | None) -> tuple[dict, dict]:
        """The state and questions for one turn, apart from the call, so the
        eval (drills/classifier_eval.py) asks exactly what production asks."""
        ctx = (f"The assistant is a voice manager named {NAME}. It listens to a developer "
               "thinking aloud while supervising a fleet of coding agents, and speaks only "
               "when addressed. Lines marked 'you' are the developer; other lines were spoken "
               "by the assistant or by an agent, and the developer heard them.")
        state = {
            "context": ctx,
            "conversation_before": before,
            "agent_on_stage": " - ".join(x for x in ((stage or {}).get("name"), (stage or {}).get("goal")) if x) or None,
            "text_to_judge": utterance,
            "rules": (
                "Judge ONLY text_to_judge. conversation_before is context: 'you' is the developer, "
                "other names are the assistant or an agent speaking; a status of 'acted' or 'spoken' "
                "means that turn was already handled and must not be acted on again. "
                f"The transcriber often misspells the name {NAME}: Drinkody, Tranquillity, Tranquilly, "
                "Tranquil, Trank; a turn opening with such a word is addressed. "
                "A line that repeats what an agent or the assistant just said is the room hearing that "
                "voice again, not the developer: it is not addressed. Only the assistant can invite the "
                "next agent, send, tell or pass on a message to an agent, read back what it would send, "
                "start an agent, say which agents are live or waiting, or stop the voice: "
                "a request for one of those is addressed even when it is phrased loosely, misheard, or "
                "has no name in it. A question about the developer's own earlier WORDS ('what did I "
                "say about pricing', 'did I already tell it that') is for the assistant, which keeps "
                "their record: addressed. A question about events, plans or times ('what time did we "
                "schedule it for') is not about their words and follows the other rules."
                + (" With an agent on stage, a question about its work (status, risks, what would happen "
                   "if..., is it going well) is addressed even without the name: the assistant answers it "
                   "from that agent's record." if stage else "")
                # Explicit send only (ruled 22 Sep; measured 27 Sep): "unpublish
                # this", said at the end of a run of notes for the agent on
                # stage, was read as a send and the manager sent just those two
                # words. An instruction meant for the agent is dictation until
                # the developer asks for it to be sent.
                + " The assistant relays to an agent only when asked to (send that, tell it ..., pass it "
                  "on, have the notes agent ...). An instruction meant for the agent itself, said without "
                  "asking the assistant to send it ('unpublish this', 'keep going', 'drop that field'), is "
                  "the developer dictating notes for later: not addressed."),
        }
        return state, {
            "addressed": {"type": "noul",
                "instructions": (f"In text_to_judge, is the developer asking the assistant {NAME} to speak "
                                 "or act RIGHT NOW? Earlier turns do not count; only this text."),
                "criteria": {"true": (f"Names {NAME}, or asks or instructs the assistant directly"
                                      + (", or asks about the agent on stage: its goal, findings, next step, reasons, "
                                         "or asks the assistant to send or tell it something"
                                         if stage else "")),
                             "false": ("Thinking aloud, a rhetorical question, talking to another "
                                       f"person, reading text aloud, or the word {NAME.lower()} used for something else")}},
            "intent": {"type": "choice",
                "instructions": "If text_to_judge is a request to the assistant, which kind is it?",
                "criteria": {i.value: d for i, d in INTENTS.items()}},
        }

    async def names_agent(self, utterance: str, agent: str) -> float:
        """Does this request name, or unmistakably point at, this agent? Asked
        only when nobody is on stage and the loop chose a destination: without
        it the loop sent "send that over" to whichever agent the words sounded
        like, 5 times in 5 (27 Sep, drills/send_eval.py w3)."""
        answers = await self.ask(
            {"request": utterance, "agent": agent},
            {"names": {"type": "noul",
                       "instructions": "Does the request name this agent, or point at it so plainly that no other "
                                       "agent could be meant (by its name, its project, or what it is working on)?",
                       "criteria": {"true": "The request names or plainly points at this agent",
                                    "false": "The request names no agent, or names a different one; guessing from "
                                             "what the message is about does not count"}}})
        return float(answers["names"]["noul"])

    async def harness(self, utterance: str) -> str:
        """Which coding agent a start asks for: "codex" or "claude". Asked of the
        classifier, never found by the word (hf-7); anything else is Claude Code."""
        try:
            answers = await self.ask(
                {"text_to_judge": utterance},
                {"harness": {"type": "choice",
                             "instructions": "Which coding agent is the developer asking to start?",
                             "criteria": {"claude": "Claude Code, Claude, or no agent named",
                                          "codex": "Codex"}}})
        except Exception as e:
            logger.warning(f"harness question failed: {e}; starting Claude Code")
            return "claude"
        return "codex" if _chosen(answers["harness"]) == "codex" else "claude"




NOTES_SEED = (
    "You are the Notes keeper for Tranquility Base. Every message you receive from now on is "
    "a note dictated by voice. For each one: append it verbatim under a timestamp heading to "
    "notes.md in your own agent directory (~/Documents/agents/<your session id>/), and keep "
    "notes.html there current as one readable page of all notes, newest first, titled Notes. "
    "Reply with one short sentence confirming the note. Never ask questions."
)


def note(ln: Line):
    """What was said, by whom, for a person to read later and for the models to
    see as context. The exchange (the models' tail) and the count are this
    session's own; see session.py. Every line also goes out whole as a `said`
    event, numbered, so the app holds the full record; there is no transcript
    on disk where the bot runs (hf-20)."""
    s = session.current()
    ln = Line(ln.role, ln.kind, ln.text.strip(), ln.speaker, ln.target, ln.target_name)
    s.exchange.append(ln)
    del s.exchange[:-session.EXCHANGE_KEEP]
    s.said += 1
    rec = line("said", n=s.said, **ln.said_fields())
    from wire import outbox
    outbox().put_nowait(rec)  # the app keeps the `said` lines; nothing on disk here


def exchange_lines(n: int = 8) -> list[str]:
    return [f"{ln.jev_who} ({ln.jev_status}): {ln.jev_text}" for ln in session.current().exchange[-n:]]


BRIEF_FIELDS = ("goal", "recap", "proposal", "findings", "solution", "why", "lastAssistantMessage")

# What the loop is told (hf-6). It reads; it never acts.
LOOP_SYSTEM = (
    f"You are {NAME}, the hands-free manager of a developer's coding agents. The developer "
    "asked you something aloud. Find the answer with the tools, then answer.\n"
    "- Read before you answer. A question about an agent's work is answered from its brief "
    "and, for anything the brief does not settle (risks, what would happen if, what it tried, "
    "what it said last, any detail), from its transcript. A question across agents starts "
    "from who is live and who is waiting. A question about what the developer said, at any "
    "time, is answered from notes. For the agent on stage you are already given its "
    "brief, the end of its transcript, and the passages anywhere in it that best match the "
    "question. A question about what happened earlier (what was first asked, an early "
    "decision) is answered from the matching passages, not from the end. When none of these "
    "settle it, search the transcript with other key words (names, numbers).\n"
    "- Answer only from what you were given and what the tools returned, with the specifics "
    "that answer it: the number, the name, the reason, what it hangs on. If the record does "
    "not say, say so in one sentence. Never guess, never fill a gap with what is likely, and "
    "never give generic advice. A "
    "decision the record shows is still open (a question the agent asked the developer) is "
    "open: say so, and say what it hangs on. If a transcript could not be read, say you could "
    "not read it; never take that to mean nothing was said.\n"
    "- At most 30 words, one or two sentences, spoken aloud; across agents, name at most three "
    "and say how many more. Plain words only, no lists, no "
    "markdown, no quotation marks around names, and never an id, hash, path, URL, branch or "
    "file name.\n"
    "- You only read. You cannot send, start, invite or change anything, and never say you did.")
# What the loop is told when the developer asks it to send (hf-6 step 2). It
# points; it never writes: the words sent are copied from what was said, and
# span.check refuses anything else. The four examples are the span picker's,
# measured on 12 real sends (23 Sep) before the picker was folded in here.
LOOP_ACT = (
    f"You are {NAME}, the hands-free manager of a developer's coding agents. The developer "
    "asked you to send a message to one of them (or to take a note). You decide WHETHER to "
    "send and TO WHOM; which of their words are the message is picked after you, by the "
    "app, from what they said. You never write the message.\n"
    "You are given the numbered lines they said since the last message was sent, the request, "
    "who is on stage, and the active agents. End with exactly one act:\n"
    "- send(agent) when the message is in those lines or in the request itself. Leave `agent` "
    "out for the agent on stage; otherwise the id of the agent the request names. When the "
    "request names a stretch of what they said beyond those lines ('what I said about "
    "pricing', 'the last ten minutes'), pass `range` with key words or minutes.\n"
    "- ask(question) when you cannot tell which agent it is for: nobody is on stage and the "
    "request names no agent, or it could mean two. One short question.\n"
    "- wait() when they have not said the message yet ('send a message to it' with nothing "
    "said): the manager keeps listening.\n"
    "`range` is only for a request that names a topic or a time to take from their whole "
    "record ('what I said about pricing', 'this morning', 'the last ten minutes', 'everything "
    "today'): that is a range, never a wait, even when no lines are listed above. 'That', "
    "'it', 'that message', 'what I just said' mean the lines listed above: no range.\n"    "In a range, a day ('today', 'yesterday', 'on Tuesday', 'everything today') is `day` as "
    "YYYY-MM-DD; 'the last N minutes' is `since_minutes`; a topic is `query`. Never narrow what "
    "they asked for: 'everything today' is the whole day.\n"
    "The agent the request names wins over the one on stage: 'send what I said about pricing to "
    "the site agent', with Mailchimp on stage, is send(agent=<the site agent's id>, "
    "range={query: 'pricing'}).\n"
    "Never pick an agent by guessing from what the message is about.")

# How much of a range may be sent in one go (ruled 27 Sep): past this the loop
# asks the developer to narrow it rather than sending a wall of text.
READ_BACK_WORDS = 40  # of a dry run, read aloud; the count of the rest is said
RANGE_LINES = 60
RANGE_CHARS = 8000

TAIL_CHARS = 7000  # of the staged agent's transcript, given to the loop up front
MATCH_CHARS = 6000  # of its passages matching the question, also up front
SPOKEN_WORDS = 30  # what an answer may run to aloud; longer is cut down by the model once (loop.py)
LOOP_AS_AGENT = ("\n- You are answering AS the agent on stage, in its own voice: first person "
                 "plural ('we found', 'we propose').")


def _now_line() -> str:
    """The time, so 'yesterday' and 'the last ten minutes' can become a window.
    In the Mac's zone (its hello says), else TB_TZ, else UTC, named."""
    from datetime import datetime
    from zoneinfo import ZoneInfo
    import wire
    tz = wire.current().tz or os.getenv("TB_TZ") or "UTC"
    try:
        now = datetime.now(ZoneInfo(tz))
    except Exception:
        now, tz = datetime.now(ZoneInfo("UTC")), "UTC"
    return now.strftime(f"%A %d %B %Y, %H:%M ({tz})")


def _chosen(choice: dict) -> str:
    # A Jev choice answer: {"choice": name, "confidence": c, "probabilities": {name: p}}.
    probs = choice.get("probabilities") or {}
    return choice.get("choice") or (max(probs.items(), key=lambda kv: kv[1])[0] if probs else "none")


class Brain:
    """The span picker's one completion (it only points; span.py), and the
    local transcript reader. Questions are the loop's (loop.py)."""

    def __init__(self):
        self._client = httpx.AsyncClient(
            base_url=os.getenv("GC_BASE_URL", "https://api.generalcompute.com/v1"),
            headers={"Authorization": f"Bearer {os.environ.get('GC_API_KEY', '')}"},
            # 03:30:26: a capabilities question waited the full 20 s on a hung
            # completion with the orb on "explaining", then fell back to the
            # fixed line anyway. A spoken answer that is not there in 8 s is
            # not coming; the fallbacks are written for that.
            timeout=8.0)
        self.model = os.getenv("GC_MODEL", "minimax-m2.7")

    @staticmethod
    def _turns(path: str | None, window: int | None = 400_000) -> list[tuple[str, str]]:
        """Every text turn in a transcript file, oldest first; `window` reads
        only its last that many bytes."""
        if not path or not os.path.exists(path):
            return []
        turns = []
        try:
            with open(path, "rb") as f:
                if window:
                    f.seek(max(0, os.path.getsize(path) - window))
                for raw in f.read().decode(errors="replace").splitlines():
                    try:
                        o = json.loads(raw)
                    except Exception:
                        continue
                    who, c = Brain._turn_of(o)
                    if who and c:
                        turns.append((who, c))
        except Exception as e:
            logger.warning(f"transcript read failed: {e}")
        return turns

    @staticmethod
    def _turn_of(o: dict) -> tuple[str | None, str]:
        """One transcript line as (who, text), or (None, "") when it is not a
        spoken turn. Claude Code writes {type, message}; Codex writes
        {type: response_item, payload: {type: message, role, content}}."""
        if o.get("type") in ("assistant", "user"):
            who, c = o["type"], (o.get("message") or {}).get("content")
        elif o.get("type") == "response_item" and (o.get("payload") or {}).get("type") == "message" \
                and o["payload"].get("role") in ("assistant", "user"):
            who, c = o["payload"]["role"], o["payload"].get("content")
        else:
            return None, ""
        if isinstance(c, list):
            c = " ".join(p.get("text", "") for p in c if isinstance(p, dict)
                         and p.get("type") in ("text", "input_text", "output_text"))
        return (who, c.strip()) if isinstance(c, str) and c.strip() else (None, "")

    @staticmethod
    def transcript_tail(path: str | None, limit: int = 7000) -> str:
        """The last stretch of the session's own transcript: what it and its
        supervisor actually said, text parts only."""
        return "\n".join(f"{who}: {text}" for who, text in Brain._turns(path))[-limit:]

    @staticmethod
    def transcript_search(path: str | None, query: str, limit: int = 9000) -> str:
        """The turns anywhere in the transcript that best match the query, in
        the order said: the same as the Mac's TranscriptTail.search. A word
        counts by how rare it is in this session (log N/df), so the one turn
        with "salary" outranks forty with "the" and "raise"."""
        import math
        turns = Brain._turns(path, window=None)
        words = {w for w in re.split(r"[^\w]+", query.lower()) if len(w) >= 3}
        if not words or not turns:
            return ""
        lows = [t.lower() for _, t in turns]
        weight = {w: math.log((len(lows) + 1) / (1 + sum(w in t for t in lows))) for w in words}
        scored = [(sum(weight[w] for w in words if w in t), i) for i, t in enumerate(lows)]
        scored = sorted((x for x in scored if x[0] > 0), key=lambda x: (-x[0], -x[1]))
        picked, used = [], 0
        for _, i in scored:
            who, text = turns[i]
            if len(text) > 1500:
                low = lows[i]
                first = min((low.find(w) for w in sorted(words, key=lambda w: -weight[w]) if w in low), default=0)
                start = max(0, first - 500)
                text = ("…" if start else "") + text[start:start + 1500] + ("…" if start + 1500 < len(text) else "")
            if used + len(text) > limit and picked:
                break
            picked.append((i, f"[turn {i + 1}] {who}: {text}"))
            used += len(text)
        return "\n".join(t for _, t in sorted(picked))

    async def pick_span(self, request: str, cands: list, agent: str, goal: str | None) -> dict | None:
        """Which of the developer's own lines are the message, or which part of
        the request is (span.py). The model only points; it writes nothing that
        is sent. Returns its answer as JSON, checked by span.check."""
        numbered = "\n".join(f"[{c.n}] {c.text}" for c in cands) or "(none)"
        msgs = [
            {"role": "system", "content": (
                "A developer speaking to a voice assistant has asked it to send a message to a coding agent. "
                "You decide WHICH of their own words are that message. You never write, fix or rephrase "
                "anything: you only point. Answer with exactly one JSON object and nothing else:\n"
                '{"lines": [FROM, TO]}  when the message is a contiguous run of the numbered lines they '
                "said earlier (use their numbers; leave out chatter that is not for the agent);\n"
                '{"quote": "..."}  when the message is inside the request itself, copied character for '
                "character from it (for 'tell it yes, go ahead' the quote is 'yes, go ahead');\n"
                '{"none": true}  when they have not said the message yet, or you cannot tell which words are it.\n'
                "A request that only says where or whether to send (\"send that to it\", \"to the same agent\", "
                "\"send it over\") is not itself the message: point at their earlier lines, or answer none.\n"
                "Examples:\n"
                "Lines [4] The deploy script skips the second agent. [5] Can you make it deploy both. "
                "Request: send that to the deploy agent -> {\"lines\": [4, 5]}\n"
                "Lines [9] Right. Request: tell it yes, merge it -> {\"quote\": \"yes, merge it\"}\n"
                "Lines [2] Coffee's cold again. Request: send a message to the build agent -> {\"none\": true}\n"
                "Lines [6] The export drops the footer. [7] Also the images are stale. "
                "Request: and to the same one -> {\"lines\": [6, 7]}")},
            {"role": "user", "content": (
                f"Agent: {agent}" + (f", working on: {goal}" if goal else "") + "\n"
                f"Request: {request}\n"
                f"Their lines since the last message was sent (oldest first):\n{numbered}")},
        ]
        body = {"model": self.model, "messages": msgs, "max_tokens": 400, "temperature": 0}
        # It answers in about 0.6 s; now and then the provider stalls past 8 s
        # (2 of 36 picks, 23 Sep). A pick changes nothing, so a stalled one is
        # abandoned at 4 s and asked once more rather than waited out.
        for attempt in (1, 2):
            t0 = time.monotonic()
            try:
                r = await self._client.post("/chat/completions", json=body, timeout=4.0)
            except httpx.TimeoutException:
                logger.warning(f"span pick stalled past 4 s (attempt {attempt})")
                if attempt == 2:
                    raise
                continue
            r.raise_for_status()
            record("brain", body, r.json(), ms=int((time.monotonic() - t0) * 1000))
            return span.parse_answer(r.json()["choices"][0]["message"].get("content") or "")
        return None



class Manager(FrameProcessor):
    def __init__(self, jev: JevClient, tts=None):
        super().__init__()
        self._jev = jev
        # The one mouth. Every line this Mac says aloud comes down the
        # connection now, a session's announcement included, so the canceller
        # has all of it and the microphone never has to close. Held directly
        # rather than addressed through a frame because changing the speaker
        # means reconnecting the socket; see SpokenTTSService.use_voice.
        self._tts = tts
        self._manager_voice = None
        self._brain = Brain()
        self._loop = Loop()
        self._recent: list[str] = []
        self._last_intent: Intent | None = None
        # Each intent's handler, named once. Found by building "_do_<label>"
        # before hf-26: a renamed label was not an error, only a handler that
        # silently never ran. Every intent has one; questions go to the loop.
        self._handlers = {
            Intent.MUTE: self._do_mute, Intent.NONE: self._do_none,
            Intent.INVITE_NEXT: self._do_invite_next,
            Intent.RUNG_GOAL: self._do_rung_goal, Intent.RUNG_FINDINGS: self._do_rung_findings,
            Intent.RUNG_SOLUTION: self._do_rung_solution, Intent.RUNG_WHY: self._do_rung_why,
            Intent.CUSTOM: self._do_custom, Intent.TEACH: self._do_teach, Intent.SPEAK: self._do_speak,
            Intent.FLEET_STATUS: self._do_fleet_status, Intent.SUMMARIZE_RECENT: self._do_summarize_recent,
            Intent.SEND_MESSAGE: self._do_send_message, Intent.START_AGENT: self._do_start_agent,
            Intent.READ_BACK: self._do_read_back,
        }
        self._last_intent_at = 0.0
        self.stage: dict | None = None
        self._wire_task = None  # hosted: drains wire.outbox into transport messages
        self._log_task = None  # hosted: drains wire.logbox, the model calls, behind it
        self._idle_task = None  # hosted: ends the session after IDLE_SECS without speech
        self._mac_task = None   # hosted: follows the panel's stage (hf-16)
        self._last_heard = time.monotonic()
        self.heard = 0
        self.addressed = 0
        self._bot_stopped = asyncio.Event()
        self._voice = asyncio.Lock()        # one voice at a time, manager or agent
        self._held: str | None = None       # a turn that ended mid-sentence, waiting for its rest
        self._user_speaking = False         # between on_user_turn_started and the next context frame
        self._held_task: asyncio.Task | None = None
        # Every turn, in the order said, decided one at a time (turns.py, hf-13).
        self._turns = TurnQueue(self._dispatch)
        self._turns_task: asyncio.Task | None = None
        self._early: set[asyncio.Task] = set()  # stops heard while a turn is in flight

    async def _say_and_wait(self, text: str, timeout: float = 8.0):
        await self._say(text)  # _say already waits for its own voice to stop

    async def _follow_mac(self):
        """The panel's attention, followed (hf-16, "follow", ruled 27 Sep). A
        shortcut acts at once on the Mac; the Mac then says who is in focus, and
        that agent becomes the stage, so "send that to it" after ⌃⌥ means the
        agent just heard. Nothing is spoken and nothing else changes."""
        import wire
        q = wire.current().mac_events
        while True:
            ev = await q.get()
            if wire.MacEvent(ev.get("event")) is wire.MacEvent.STAGE and ev.get("session"):
                self._follow_stage(ev)

    def _follow_stage(self, ev: dict):
        sid = ev["session"]
        if (self.stage or {}).get("sessionId") == sid:
            return
        self.stage = {"sessionId": sid, "name": ev.get("name"), "goal": ev.get("goal"), "project": ""}
        logger.info(f"stage follows the panel ({ev.get('via')}): {sid[:8]} {ev.get('name') or ''}")

    async def _drain_wire(self):
        """Hosted: every event line and door request becomes a text frame on the
        socket, pushed from inside the pipeline so ordering holds."""
        from pipecat.frames.frames import OutputTransportMessageUrgentFrame
        from wire import outbox
        q = outbox()
        while True:
            msg = await q.get()
            await self.push_frame(OutputTransportMessageUrgentFrame(message=msg))

    async def _drain_log(self):
        """Hosted: every model call, in full, to this session's Mac (hf-14).
        Written off the turn: `record` only queues, and this sends a part at a
        time, each after the outbox has nothing waiting, so a record never
        delays a line the panel or a door is waiting for."""
        import calls
        from pipecat.frames.frames import OutputTransportMessageFrame
        from wire import logbox, outbox
        box, lines = logbox(), outbox()
        while True:
            rec = await box.get()
            for part in calls.parts(rec, uuid.uuid4().hex[:8]):
                while not lines.empty():
                    await asyncio.sleep(0.05)
                await self.push_frame(OutputTransportMessageFrame(message=part))

    async def _end_when_idle(self):
        started = time.monotonic()
        while True:
            now = time.monotonic()
            idle_in = IDLE_SECS - (now - self._last_heard)
            rotate_in = SESSION_LIFE_SECS - (now - started)
            if idle_in > 0 and rotate_in > 0:
                await asyncio.sleep(min(idle_in, rotate_in, 30))
                continue
            busy = self._user_speaking
            if busy:  # mid-sentence: look again shortly
                if idle_in <= 0:
                    self._last_heard = now
                await asyncio.sleep(5)
                continue
            if idle_in <= 0:
                logger.info(f"idle for {IDLE_SECS:.0f}s: ending the session")
                await emit(None, "idle", secs=int(IDLE_SECS))
            else:
                logger.info(f"session life {SESSION_LIFE_SECS:.0f}s reached: rotating")
                await emit(None, "rotate", secs=int(SESSION_LIFE_SECS))
            await asyncio.sleep(0.5)  # the line leaves before the socket closes
            await self.push_frame(EndWorkerFrame())
            return

    async def cleanup(self):
        for name in ("_wire_task", "_log_task", "_idle_task", "_mac_task"):
            task = getattr(self, name)
            if task:
                await self.cancel_task(task)
                setattr(self, name, None)
        await super().cleanup()

    async def hearing(self):
        """The user started speaking: the orb shows it before any verdict."""
        self._user_speaking = True
        self._last_heard = time.monotonic()
        await emit(self, "hearing")

    # -- pipeline entry ------------------------------------------------------------

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, StartFrame):
            if self._turns_task is None:
                self._turns_task = self.create_task(self._turns.run())
            if self._wire_task is None:
                self._wire_task = self.create_task(self._drain_wire())
                self._log_task = self.create_task(self._drain_log())
                self._mac_task = self.create_task(self._follow_mac())
                self._last_heard = time.monotonic()
                self._idle_task = self.create_task(self._end_when_idle())
            # The pipeline is running and the mic is open: now it is listening.
            # Both: main's build stamp on the ready line, and the data
            # channel's replies.
            await emit(None, "ready", build=build_stamp.stamp()["sha"])
        if isinstance(frame, InputTransportMessageFrame):
            # A door's answer over a data channel (WebRTC). Over the WebSocket
            # the same JSON arrives through the serializer; the shapes are the
            # same and only the carriage differs.
            import wire as _wire
            message = frame.message
            # The client stamps a `type` on its replies because the data
            # channel drops anything without one; it is not part of the
            # contract and nothing reads it here.
            if isinstance(message, str):
                try:
                    message = json.loads(message)
                except ValueError:
                    message = None
            if isinstance(message, dict):
                _wire.take_reply(message)
        if isinstance(frame, InterruptionFrame):
            self._interrupted()
        if isinstance(frame, BotStartedSpeakingFrame):
            session.current().bot_voice["speaking"] = True  # the echo gate reads this
        if isinstance(frame, BotStoppedSpeakingFrame):
            voice = session.current().bot_voice
            voice["speaking"] = False
            voice["stopped_at"] = time.monotonic()
            self._bot_stopped.set()
            await emit(None, "quiet")  # the manager's voice stopped; the orb goes back to rest
        if not isinstance(frame, LLMContextFrame):
            await self.push_frame(frame, direction)
            return
        if frame.speculation:
            return
        text = _last_user_text(frame)
        self._user_speaking = False
        if not text:
            await self.push_frame(frame, direction)
            return
        # A turn cut mid-sentence (no terminal punctuation) waits for its
        # continuation; the two are judged as one. 16:58:32: "…the risks,
        # tradeof" / "uncertainties we're still facing" were judged separately
        # and both spoke, on top of each other. 17:26:12: "Tranquillity, can you"
        # was three words, under the old four-word floor, so it was judged alone,
        # spoke a status line, and "tell us about your capabilities?" 1.9 s later
        # spoke again. A fragment that names the manager will speak whatever
        # follows, so it waits longer for the rest.
        if self._held is not None:
            if self._held_task:
                self._held_task.cancel()
            text = (self._held + " " + text).strip()
            self._held = None
            logger.info(f"joined turn: {text[:80]}")
        # A fragment waits for its rest when it was cut mid-sentence, and also
        # when it is only the manager's name: the transcriber ends a final
        # after the vocative often enough that judging it alone costs a
        # duplicate answer every time.
        if not text.rstrip().endswith((".", "?", "!")) or only_the_name(text):
            self._held = text
            wait = HOLD_NAMED_SECS if names_the_manager(text) or only_the_name(text) else HOLD_SECS
            self._held_task = asyncio.create_task(self._release_held(frame, direction, wait))
            return
        self._enqueue(text, frame, direction)

    def _interrupted(self):
        """Talked over: the voice stops (Pipecat's own interruption, which only
        a client that cancels its echo lets through) and so does the turn it
        belonged to, so the rest of that turn is never said. Every turn start
        is an interruption frame; only one said over the manager's voice is a
        barge-in."""
        if session.current().bot_voice.get("speaking"):
            self._turns.cut("talked over")

    def _enqueue(self, text, frame, direction):
        self.heard += 1
        busy = self._turns.busy
        self._turns.put((text, frame, direction))
        self._recent.append(text)
        if busy:
            task = asyncio.create_task(self._look_early(text))
            self._early.add(task)
            task.add_done_callback(self._early.discard)

    async def _release_held(self, frame, direction, wait: float):
        await asyncio.sleep(wait)
        # The rest is on its way: the user started again before the hold ran
        # out. 02:58:03: "Okay, can you invite the next" was released at 1.2 s
        # while "agent to speak, please?" was still being said, both were
        # judged invite_next, and two agents were invited. The turn that ends
        # this speech joins the held text on arrival and clears it.
        # Capped: a VAD false start with no words behind it would otherwise
        # hold the fragment until the next thing said.
        for _ in range(80):
            if not (self._user_speaking and self._held is not None):
                break
            await asyncio.sleep(0.1)
        text, self._held = self._held, None
        if text:
            self._enqueue(text, frame, direction)

    async def _dispatch(self, turn: tuple):
        """One turn, when every turn before it has finished."""
        text, frame, direction = turn
        await self._handle_turn(text, frame, direction)

    async def _handle_turn(self, text, frame, direction):
        try:
            await self._turn(text, frame, direction)
        except FileNotFoundError as e:  # a read door is missing: say so, never infer
            logger.error(f"manager read failed: {e}")
            await emit(self, "error", reason=_why(e))
            await self._say("I can't read the fleet right now.")
        except Exception as e:  # the manager fails closed: silence, never a crash
            logger.exception(f"manager turn failed: {e}")
            await emit(self, "error", reason=_why(e))
            # Failing closed is right when the manager cannot tell whether it
            # was addressed -- it listens to a room all day and must not answer
            # it. But when the first word is its own name, being addressed is
            # not in doubt, and silence is the manager appearing broken while
            # it is merely unable to think. 28 Sep: four turns in a row died
            # here and the panel showed a bare "error" with nothing after it.
            if isinstance(e, DoorRefused):
                await self._say("I could not read the fleet just now. Try that again.")
            elif names_the_manager(text):
                await self._say("Something went wrong judging that. Say it again.")

    async def _judge(self, text: str):
        """Is this turn for the manager, and what does it want? One judgement,
        whether the turn is handled now or looked at early (`_look_early`)."""
        t0 = time.monotonic()
        p, intent_answer = await self._jev.turn(text, self._recent, self.stage)
        ms = int((time.monotonic() - t0) * 1000)
        jev = dict(self._jev.last)
        # The classifier's answer is the decision. Four rules used to sit on
        # top of it (the name's sound, a confident fleet command, a question
        # about the stage, "what's next" with nobody on stage); measured on
        # 101 labelled real turns, three runs each, two of them never changed
        # a decision and the others were matched by saying the same things in
        # the classifier's context, with half the false yeses (hf-7,
        # drills/classifier_eval.py).
        return p, parse_intent(_chosen(intent_answer)), ms, jev

    async def _look_early(self, text: str):
        """Hear a stop now, not after the turn it is meant to stop (hf-25).
        Turns are handled in order, so "stop" said while the manager thinks
        about the last one used to wait behind it and the answer was spoken
        anyway. While a turn is in flight, each new one is also judged on
        arrival; if it is addressed and it is a stop, the turn in flight is
        cut and anything still playing is interrupted. It stays queued: when
        reached it is judged again and mutes the app's voice as always."""
        p, intent, _, _ = await self._judge(text)
        if p >= THRESHOLD and intent is Intent.MUTE and self._turns.cut("told to stop"):
            await self.broadcast_interruption()
            await emit(self, "listening", p=round(p, 2), intent=intent.value, text=text)

    async def _turn(self, text, frame, direction):
        p, intent, ms, jev = await self._judge(text)
        await emit(self, "jev", ms=jev.get("ms"), state=jev.get("state"), answers=jev.get("answers"))
        speak = p >= THRESHOLD
        logger.info(f"gate p={p:.2f} {intent.value} {ms}ms {'SPEAK' if speak else 'silent'} :: {text[:80]}")
        note(Line(Role.USER, LineKind.COMMAND if speak else LineKind.TALK, text))
        await emit(self, "addressed" if speak else "listening",
                   p=round(p, 2), intent=intent.value if speak else None, ms=ms, text=text)
        if not speak:
            return
        # One sentence, one action. 02:58, 22 Sep: "Okay, can you invite the
        # next" and "agent to speak, please?" arrived half a second apart, both
        # were judged invite_next, and two agents were invited. The hold joins
        # what it can; this catches what it cannot.
        now = time.monotonic()
        if intent == self._last_intent and now - self._last_intent_at < REPEAT_SECS:
            logger.info(f"dropping a second {intent.value} {now - self._last_intent_at:.1f}s after the first")
            await emit(self, "listening", p=round(p, 2), ms=ms, text=text)
            return
        self._last_intent, self._last_intent_at = intent, now
        self.addressed += 1
        # The activation cue covers latency you would otherwise fill by repeating
        # yourself. An invite or a rung speaks within a second; a cue there lands
        # on top of the voice. Only the slow intents get one.
        if intent in SLOW_INTENTS:
            await self._earcon("listening")
        await self._handlers[intent](text, frame, direction)

    # -- intents handled without the LLM ---------------------------------------------

    async def _do_mute(self, text, frame, direction):
        """Stop whoever is talking: the app's voice via the mute verb, and the
        manager's own by interrupting it. An answer from the model is spoken
        outside any turn (the LLM service, then TTS), so ending the turn that
        asked for it stops nothing; only an interruption reaches it (hf-25)."""
        await self.broadcast_interruption()
        await emit(self, "tool", argv=["open", f"{SCHEME}://mute"])
        await effect(_run("open", f"{SCHEME}://mute"))

    async def _do_none(self, text, frame, direction):
        pass  # the activation cue already played; nothing to add

    async def _do_invite_next(self, text, frame, direction):
        # The name first, if the sentence carries one. "Invite the SambaNova
        # agent" and "invite the next agent" are the same intent to the gate --
        # there is one invite verb -- and the difference between them is in the
        # words, which this is handed and used to throw away.
        nxt = await self._named_session(text) or await self._next_session()
        if not nxt:
            # Not "no live sessions": there are usually a dozen, and saying
            # otherwise while the grid shows them reads as the manager being
            # blind. What is true is that none of them is waiting on you, and
            # a session that is not waiting is not the manager's to interrupt.
            await self._say("Nobody is waiting on you. Name an agent if you want one.")
            return
        self.stage = nxt
        await emit(self, "stage", session=nxt["sessionId"], goal=nxt.get("goal"),
                   name=nxt.get("name"), project=nxt.get("project"))
        # Shielded from the announcement onward, which is the whole point.
        #
        # 27 Sep 01:39, from the app's log: the stage was taken, "Inviting
        # Tranquility base architecture review to speak" was said, `hearing`
        # fired 1.7 s later WHILE that sentence was still playing, and the
        # invitation died there. The panel sat on the promise with nobody
        # speaking and no error anywhere, because a cancelled task is not a
        # failure.
        #
        # Shielding only the half after the announcement would not have saved
        # it: the breath that cancels lands during the sentence, not after it.
        # So the promise and everything that keeps it are one act. An
        # interruption may stop the manager TALKING — the TTS hears that
        # directly — but it must not undo something the manager has already
        # said it is doing.
        #
        # turns.py named this before it happened again: "an invite that died
        # between 'Inviting…' and the hear verb once left nobody speaking".
        # Starting an agent was shielded for it; inviting one was not.
        await effect(self._invite(nxt))

    async def _invite(self, nxt: dict):
        """Say who is coming, then let them speak. One act, once begun."""
        who = nxt.get("name") or nxt.get("project") or "the next agent"
        await self._say_and_wait(f"Inviting {who} to speak.")
        await asyncio.sleep(0.2)  # a breath between the manager's voice and the agent's
        brief = await self._brief(nxt["sessionId"])
        spoken = " ".join(x for x in ((brief or {}).get("recap"), (brief or {}).get("proposal")) if x)
        # No `speaking` emit here. `_app_speaks` -> `_say` emits one for this
        # same line a breath later, and both were going out: 27 Sep 22:39:47.386
        # and .968, identical, 0.58s apart, so the panel announced every agent
        # twice. This one is the older of the two, from when saying who was
        # coming and letting them speak were separate steps; the one inside
        # `_say` is the real one, because it fires when the voice actually
        # starts and carries the voice id that will read it.
        note(Line(Role.AGENT, LineKind.SPOKEN, spoken or "(no brief stored)",
                  speaker=nxt.get("name") or nxt.get("goal") or nxt["sessionId"][:8]))
        await self._app_speaks(f"{SCHEME}://hear?session={nxt['sessionId']}", spoken or "x " * 20,
                               nxt["sessionId"])

    async def _do_rung_goal(self, t, f, d): await self._rung("goal", t, f, d)
    async def _do_rung_findings(self, t, f, d): await self._rung("findings", t, f, d)
    async def _do_rung_solution(self, t, f, d): await self._rung("solution", t, f, d)
    async def _do_rung_why(self, t, f, d): await self._rung("why", t, f, d)

    async def _rung(self, kind: str, text, frame, direction):
        if not self.stage:
            await self._say("Nobody is on stage yet. Say invite the next agent.")
            return
        brief = await self._brief(self.stage["sessionId"])
        rung = next((r for r in (brief or {}).get("rungs", []) if r["kind"] == kind), None)
        if not rung:
            # No stored rung for that question: answer it from the session's own
            # context (brief, last message), in the session's voice.
            await self._answer_about_stage(text, brief)
            return
        # The session speaks its own rung: a speak-only deep link into the app.
        await emit(self, "speaking", voice="agent", session=self.stage["sessionId"],
                   rung=kind, text=rung["spoken"])
        note(Line(Role.AGENT, LineKind.SPOKEN, rung["spoken"],
                  speaker=self.stage.get("name") or self.stage.get("goal") or self.stage["sessionId"][:8]))
        await self._app_speaks(f"{SCHEME}://rung?session={self.stage['sessionId']}&kind={kind}",
                               rung["spoken"], self.stage["sessionId"])

    async def _do_custom(self, text, frame, direction):
        if not self.stage:
            await self._ask_loop(text)
            return
        # A question is answered, never sent: an instruction for the agent is
        # the classifier's SEND_MESSAGE, and goes to _act (hf-6 step 2).
        await self._answer_about_stage(text, await self._brief(self.stage["sessionId"]))

    async def _answer_about_stage(self, question: str, brief: dict | None):
        """A question about the session on stage, answered by the loop and
        spoken by the session, in its own voice."""
        await self._ask_loop(question, as_stage=True)

    async def _do_summarize_recent(self, text, frame, direction):
        await self._ask_loop(text)

    async def _ask_loop(self, question: str, as_stage: bool = False):
        """A question, answered by reading (loop.py, hf-6). The manager's voice
        says it, or the staged agent's when the question is about its work."""
        from urllib.parse import quote
        stage = self.stage if as_stage else None
        holding: list[asyncio.Task] = []

        async def hold(line: str):
            holding.append(asyncio.create_task(self._say(line)))

        outcome = await self._answer(question, as_stage, on_hold=hold)
        for t in holding:
            await t
        if not outcome.answer:
            await self._say("I couldn't find that in time." if outcome.stopped in ("time", "steps")
                            else "I couldn't get an answer right now.")
            return
        answer = spoken(outcome.answer)
        if not stage:
            await self._say(answer)
            return
        sid = stage["sessionId"]
        await emit(self, "speaking", voice="agent", session=sid, text=answer)
        note(Line(Role.AGENT, LineKind.SPOKEN, answer, speaker=stage.get("name") or stage.get("goal") or sid[:8]))
        await self._app_speaks(f"{SCHEME}://say?session={sid}&text={quote(answer)}", answer, sid)

    async def _answer(self, question: str, as_stage: bool = False, on_hold=None):
        """The loop's answer, unspoken (drills/loop_eval.py asks this too)."""
        who = (self.stage or {})
        context = []
        if who:
            context.append(f"Agent on stage: {who.get('name') or who.get('project') or 'unnamed'}"
                           f"{' - ' + who['goal'] if who.get('goal') else ''} "
                           f"(agent id {who['sessionId']}, for tools only; never say it)")
            # Its brief, up front: the old one-shot answer always had it, and
            # the loop, left to fetch it, sometimes fetched the wrong agent's
            # (25 Sep graded eval).
            b = await self._brief(who["sessionId"])
            if b:
                context.append("Its brief: " + json.dumps({k: b.get(k) for k in BRIEF_FIELDS if b.get(k)},
                                                          ensure_ascii=False))
            # And the end of its transcript: what the one-shot answer always
            # had, and where most answers are. Left for the loop to fetch, it
            # searched instead and answered in part: 0 of 12 recent held-out
            # questions right against 7 (25 Sep). The tools reach beyond this.
            tail = await self._transcript(who["sessionId"], TAIL_CHARS)
            if tail:
                context.append(f"The end of its transcript (last {TAIL_CHARS} characters, newest last):\n{tail}")
            # And what matches the question anywhere in the session. Given only
            # the end, the loop answered early-session questions from it,
            # wrongly and with confidence (15 of 24 on the tuning half); left
            # to search on its own, it did not always search. Both are in
            # hand before it answers; the tools go further when these do not
            # settle it.
            hits = await self._transcript(who["sessionId"], MATCH_CHARS, question)
            if hits:
                context.append("Passages anywhere in its transcript that best match the question, "
                               f"in the order said:\n{hits}")
        before = exchange_lines()
        if before:
            context.append("What was said just before, oldest first (you = the developer):\n" + "\n".join(before))
        context.append(f"It is now {_now_line()}.")
        context.append(f"Question: {question}")
        outcome = await self._loop.run(LOOP_SYSTEM + (LOOP_AS_AGENT if as_stage and who else ""),
                                       "\n\n".join(context), self._loop_tools(), on_hold=on_hold,
                                       max_words=SPOKEN_WORDS)
        await emit(self, "loop", steps=outcome.steps, ms=outcome.ms, stopped=outcome.stopped,
                   calls=[{"tool": c["tool"], "ms": c["ms"]} for c in outcome.calls])
        logger.info(f"loop: {outcome.steps} steps, {outcome.ms} ms, calls "
                    f"{[c['tool'] for c in outcome.calls]}, stopped {outcome.stopped}")
        return outcome

    def _loop_tools(self) -> list[Tool]:
        """What the loop may read: all of it on this Mac when hosted (wire v1)."""
        agent = {"agent": {"type": "string", "description": "the agent's id (from agents or waiting); "
                                                             "leave it out for the agent on stage"}}

        async def resolve(a) -> str | None:
            return await self._resolve_agent(a.get("agent"))

        def unknown(a):
            return {"error": f"no agent matches {a.get('agent')!r}; use an id from agents, or leave "
                             "agent out for the agent on stage"}

        # Active means a lamp on: a live session, heard or not (ruled 26 Sep).
        # Everything the panel knows about each, so a question about the fleet
        # ("which one runs on Codex?") is answered from the list, not guessed.
        async def agents(a):
            return [{k: t.get(k) for k in ("sessionId", "name", "goal", "project", "harness", "status",
                                           "waiting", "topic") if t.get(k) is not None}
                    for t in await self._targets()]

        async def waiting(a):
            return [{k: w.get(k) for k in ("sessionId", "name", "goal", "project", "harness", "topic", "heard")
                     if w.get(k) is not None} for w in await self._live_waiting()]

        async def brief(a):
            sid = await resolve(a)
            if not sid:
                return unknown(a)
            b = await self._brief(sid)
            return {k: b.get(k) for k in BRIEF_FIELDS} if b else {"error": "no brief stored for that agent"}

        async def transcript(a):
            sid = await resolve(a)
            if not sid:
                return unknown(a)
            text = await self._transcript(sid, min(int(a.get("chars") or 7000), 30_000),
                                          (a.get("query") or "").strip())
            return text or {"error": "could not read a transcript for that agent (none found, or a "
                                     "format this reader does not know); this says nothing about "
                                     "what was said"}

        async def said(a):
            return [f"[{c.n}] {c.text}" for c in await span.candidates()]

        async def notes_read(a):
            return await self._notes((a.get("query") or "").strip(), a.get("since_minutes"),
                                     a.get("until_minutes"), min(int(a.get("limit") or 80), 200), a.get("day"))

        return [
            Tool("agents", "Every active agent (lamp on, live, heard or not): id, name, goal, project, "
                           "harness (claude-code, codex, ...), status (busy, idle, ...), whether it is "
                           "waiting on the developer, and the topic of its latest turn.", agents),
            Tool("waiting", "The active agents waiting on the developer right now, with their topic and "
                            "whether the developer has heard them yet.", waiting),
            Tool("brief", "An agent's latest brief: goal, recap, proposal, findings, solution, why, "
                          "its last message.", brief, agent),
            Tool("transcript", "An agent's own words and the developer's replies to it. With `query` (a few "
                               "key words): the turns anywhere in the whole session that match them best, "
                               "in the order said; use this for anything earlier than what you were given. "
                               "Without `query`: the most recent, newest last; `chars` (default 7000, up to "
                               "30000) reads further back.",
                 transcript, {**agent, "chars": {"type": "integer"},
                              "query": {"type": "string", "description": "key words to search the whole session for"}},
                 [], "Reading its transcript."),
            Tool("said", "What the developer has said aloud since the last message was sent, numbered.", said),
            Tool("notes", "Everything the developer has said, any time: hands-free lines and dictations "
                          "(with the agent each went to), oldest first. `query`: key words to find; "
                          "`day`: a calendar day as YYYY-MM-DD ('yesterday', 'on Tuesday'); or "
                          "`since_minutes` / `until_minutes`: a recent window, in minutes ago; `limit` (default 80).",
                 notes_read, {"query": {"type": "string"}, "day": {"type": "string"},
                              "since_minutes": {"type": "integer"}, "until_minutes": {"type": "integer"},
                              "limit": {"type": "integer"}}),
        ]

    async def _notes(self, query: str = "", since_minutes: int | None = None,
                     until_minutes: int | None = None, limit: int = 80, day: str | None = None) -> dict:
        """Everything the developer said, hands-free and dictated, from the Mac
        (ManagerNotes, wire v1 `notes`): the same record as the hub's Notes."""
        import wire
        args = {"limit": limit} | ({"query": query} if query else {}) \
            | ({"since_minutes": since_minutes} if since_minutes is not None else {}) \
            | ({"until_minutes": until_minutes} if until_minutes is not None else {}) \
            | ({"day": day} if day else {})
        r = await wire.call(wire.Tool.NOTES, args)
        if r is None:
            return {"error": "this Mac does not offer notes yet"}
        if not r.get("ok"):
            return {"error": (r.get("error") or {}).get("message") or "notes could not be read"}
        return r.get("data") or {}

    async def _resolve_agent(self, want: str | None) -> str | None:
        """The agent a tool call means: the one on stage when none is named;
        otherwise an id, a unique id prefix, or a name, never a guess."""
        want = (want or "").strip()
        if not want:
            return (self.stage or {}).get("sessionId")
        if await self._brief(want):
            return want
        live = await self._targets()
        hits = [t["sessionId"] for t in live if t.get("sessionId", "").startswith(want)]
        if len(hits) != 1:
            low = want.lower()
            hits = [t["sessionId"] for t in live
                    if low in (t.get("name") or "").lower() or low in (t.get("goal") or "").lower()]
        if len(hits) == 1:
            return hits[0]
        stage = (self.stage or {}).get("sessionId")
        return stage if stage and stage.startswith(want[:8]) else None

    async def _transcript(self, sid: str, chars: int, query: str = "") -> str:
        """The agent's own words, its latest or those matching `query`: from
        the Mac, where the file is (hf-4)."""
        import wire
        args = {"agent": sid, "chars": max(chars, 9000) if query else chars} | ({"query": query} if query else {})
        r = await wire.call(wire.Tool.TRANSCRIPT, args)
        if r is None or not r.get("ok"):
            logger.warning(f"transcript for {sid[:8]}: {((r or {}).get('error') or {}).get('code') or 'not offered'}")
            return ""
        turns = (r.get("data") or {}).get("turns") or []
        return "\n".join((f"[turn {t['turn']}] " if t.get("turn") else "") + f"{t.get('who')}: {t.get('text')}"
                         for t in turns)[-chars:]

    # Fixed, and so instant and true by construction. Measured 29 Sep against
    # the loop answering instead: one answer in ten was false ("I tell you
    # first what I would send"), one read the question as about the agent on
    # stage, and two took 8 s. The line it replaces offered "Say tell it to,
    # then your message", wrong since sends became explicit-only (22 Sep).
    CAPABILITIES = ("Ask what's next to hear the next agent, or ask about any agent's goal, findings, "
                    "next step or reasons. Ask me to send what you said to an agent, or what I would "
                    "send. Say stop to quiet a voice, or ask me to start an agent. Everything else you "
                    "say, I keep as notes.")

    async def _do_teach(self, text, frame, direction):
        """Who it is and what it can do: a fixed line, no model. Which question
        this is was the classifier's to say (TEACH, FLEET_STATUS), not a word
        list's (hf-7)."""
        await self._say("I'm Tranquility, the hands-free manager for your coding agents. " + self.CAPABILITIES)

    async def _do_fleet_status(self, text, frame, direction):
        """Which sessions are live and which are waiting on you, read aloud."""
        live = await self._targets()
        waiting = await self._live_waiting()
        if not live and not waiting:
            await self._say("I can't see any live sessions right now.")
            return
        first = (waiting or live)[0]
        who = first.get("name") or first.get("project") or "one"
        line = f"{len(live)} sessions live, {len(waiting)} waiting on you."
        line += f" First waiting: {who}." if waiting else f" First: {who}."
        await self._say(line + " Say what's next to hear it.")

    async def _do_speak(self, text, frame, direction):
        """Told to speak: one sentence about where things stand, then a door."""
        if self.stage:
            await self._say(f"Listening. On stage: {self.stage.get('name') or self.stage.get('goal') or self.stage.get('project')}. Ask for the next step, or say next agent.")
            return
        waiting = await self._live_waiting()
        if waiting:
            first = waiting[0]
            await self._say(f"Listening. {len(waiting)} waiting on you; first is {first.get('name') or first.get('project')}. Say what's next.")
        else:
            await self._say("Listening. Nobody is waiting on you. Say what's next, or name a project.")

    # -- intents that need the LLM, with the stage handed over as a note ---------------

    async def _do_send_message(self, text, frame, direction):
        """A send is a request to the manager, never a verdict read off a
        fragment of dictation (compose mode is gone, 24 Sep). The loop decides
        where and which words, pointing at what was said; the app copies them."""
        await self._act(text)

    async def _do_read_back(self, text, frame, direction):
        """Read-back on request, as a dry run (hf-11, ruled 22 Sep): the same act
        a send would take, to the same agent with the same words, said aloud
        instead of sent. Nothing is typed, nothing is recorded as sent."""
        await self._act(text, dry_run=True)

    async def _act(self, request: str, dry_run: bool = False):
        """Send (or note) by pointing (hf-6 step 2): the loop ends in one act,
        send, ask or wait, and nothing it writes is ever the message. The send
        itself happens here, after the loop, through the app's own Send."""
        cands = await span.candidates()
        who = self.stage or {}
        context = []
        if who:
            context.append(f"Agent on stage: {who.get('name') or who.get('project') or 'unnamed'}"
                           f"{' - ' + who['goal'] if who.get('goal') else ''} "
                           f"(agent id {who['sessionId']})")
        else:
            context.append("Nobody is on stage: the request says who it is for.")
        # Who could receive it, up front: left to look, it asked instead
        # (2 of 3 runs of "send that to the Mailchimp agent", 26 Sep).
        live = await self._targets()
        if live:
            context.append("Active agents (lamp on): " + "; ".join(
                f"{t.get('name') or t.get('project') or 'unnamed'} - {t.get('goal') or ''} (id {t['sessionId']})"
                for t in live[:20]))
        context.append("The Notes agent, which keeps the developer's notes, is a destination too: "
                       "send(to_notes=true).")
        before = exchange_lines()
        if before:
            context.append("What was said just before, oldest first (you = the developer):\n" + "\n".join(before))
        context.append("Their lines since the last message was sent (oldest first):\n"
                       + ("\n".join(f"[{c.n}] {c.text}" for c in cands)
                          or "(none since the last send; anything said earlier is reached with `range`)"))
        context.append(f"It is now {_now_line()}.")
        if dry_run:
            context.append("This is a dry run: they asked what you WOULD send. Choose exactly as for a "
                           "real send (send, ask or wait); nothing will be sent, it is read back to them.")
        context.append(f"Request: {request}")

        async def send(a):
            to_notes = a.get("to_notes") is True
            words, request_on_top = cands, False
            rng = a.get("range") or {}
            if rng:
                # A stretch of what they said, not just since the last send:
                # the same picker chooses the words from it, and handed to the
                # Notes agent the request goes on top, as they said it.
                got = await self._notes((rng.get("query") or "").strip(), rng.get("since_minutes"),
                                        rng.get("until_minutes"), 200, rng.get("day"))
                if got.get("error"):
                    return {"error": got["error"]}
                found = got.get("notes") or []
                if not found:
                    return {"error": "nothing they said matches that range; ask, or wait"}
                if len(found) > RANGE_LINES or sum(len(n.get("text") or "") for n in found) > RANGE_CHARS:
                    return {"error": f"that range is {len(found)} lines; ask them to narrow it "
                                     f"(at most {RANGE_LINES} lines or {RANGE_CHARS} characters)"}
                # The range ADDS to the lines since the last send, it never
                # replaces them: reached for when it was not needed ("send that
                # message as well"), a range that returned two of the three
                # lines let the picker send part of the message (3 of 5 runs,
                # 27 Sep). Older lines first, as said; a line in both, once.
                seen, merged = set(), []
                for t in [n["text"] for n in found] + [c.text for c in cands]:
                    if t not in seen:
                        seen.add(t)
                        merged.append(t)
                words = [span.Candidate(n=i + 1, text=t) for i, t in enumerate(merged)]
                request_on_top = to_notes
            if to_notes:
                # Notes are a destination like any agent: a session named Notes,
                # found while live, started (and seeded once) when not. There is
                # no "take a note" intent any more: everything said is already
                # in the record (the hub's Notes page); asking the Notes agent
                # to do something with it is a send like any other (27 Sep).
                target = await self._notes_session()
                if not target:
                    return {"error": "the notes agent could not be started; say so"}
            else:
                sid = await self._resolve_agent(a.get("agent"))
                live = {t["sessionId"]: t for t in await self._targets()}
                target = live.get(sid) or (self.stage if sid and sid == who.get("sessionId") else None)
                if not target:
                    return {"error": f"no active agent matches {a.get('agent')!r}; use agents, or ask"}
                if not who:
                    # Nobody on stage: the destination must be named, not
                    # guessed. A second opinion, not the loop's own word.
                    label = " - ".join(x for x in (target.get("name"), target.get("goal")) if x)
                    try:
                        named = await self._jev.names_agent(request, label)
                    except Exception as e:
                        logger.warning(f"names_agent failed: {e}; asking instead")
                        named = 0.0
                    if named < 0.5:
                        return {"done": True, "question": "Which agent should get it?"}
            # The words: the span picker, unchanged from main, measured on 12
            # real sends (0 wrong in 60, 23 Sep). Asked to point at the words
            # itself, the loop sent something that was not the message 8 times
            # in 85 (26 Sep, drills/send_eval.py): whether and to whom are the
            # loop's; which words stay the picker's.
            name = "Notes" if to_notes else (target.get("name") or target.get("project") or "the agent")
            try:
                answer = await self._brain.pick_span(request, words, name,
                                                     "keeping the developer's notes" if to_notes else target.get("goal"))
            except Exception as e:
                logger.error(f"span pick failed: {e}")
                answer = None
            pick = span.check(answer, words, request)
            logger.info(f"span: {len(words)} candidate lines; answer {answer}; pick {pick}")
            if not pick:
                # Nothing to point at is not an answer, it is a missing
                # argument. Measured 29 Sep, 8 runs of "send what I said about
                # the landing page to the landing agent" with another agent on
                # stage: the loop named the right agent every time and left
                # `range` out on 3 of them. Without it the picker is handed the
                # lines since the last send -- here none -- and can only say
                # none, so the turn ended in a listening cue with the developer
                # believing the message had gone.
                #
                # The loop is told, rather than the developer: a tool error is
                # not terminal, so it hears why and calls send again with the
                # range it should have passed. It cannot recur on the retry,
                # because the retry carries a range. The quote path is
                # untouched -- a message inside the request itself ("tell it
                # yes, go ahead") checks out with no candidate lines at all,
                # and never reaches here.
                if not words and not rng:
                    return {"error": "nothing was said since the last message, so there are no words to "
                                     "point at. If the request names a stretch of what they said ('what I "
                                     "said about pricing', 'the last ten minutes'), call send again with "
                                     "`range`. If they have not said the message yet, call wait."}
                return {"done": True, "waited": True, "target": target, "notes": to_notes}
            text = span.text_of(pick, words)
            if request_on_top and pick.lines is not None:
                text = f"{request.strip()}\n\n{text}"
            return {"done": True, "target": target, "text": text, "notes": to_notes}

        async def ask(a):
            q = " ".join((a.get("question") or "").split())
            return {"done": True, "question": q} if q else {"error": "ask needs a question"}

        async def wait(a):
            return {"done": True}

        reads = [t for t in self._loop_tools() if t.name in ("agents", "waiting", "brief")]
        acts = [
            Tool("send", "Send their message: to the agent on stage when `agent` is left out, otherwise to "
                         "the agent with this id. Their own words are picked after you. `range` when "
                         "the request names a stretch of what they said beyond the lines you were given "
                         "('what I said about pricing', 'the last ten minutes'): `query` key words, or "
                         "`since_minutes`. `to_notes` for the Notes agent.", send,
                 {"agent": {"type": "string"}, "to_notes": {"type": "boolean"},
                  "range": {"type": "object", "properties": {"query": {"type": "string"},
                                                             "day": {"type": "string"},
                                                             "since_minutes": {"type": "integer"},
                                                             "until_minutes": {"type": "integer"}}}},
                 terminal=True),
            Tool("ask", "Ask the developer one short question (at most 15 words) when the agent or the "
                        "words are unclear.", ask, {"question": {"type": "string"}}, ["question"], terminal=True),
            Tool("wait", "They have not said the message yet: keep listening.", wait, terminal=True),
        ]
        outcome = await self._loop.run(LOOP_ACT, "\n\n".join(context), reads + acts)
        act = outcome.action or {"tool": "wait"}
        await emit(self, "loop", mode="act", act=act["tool"], steps=outcome.steps, ms=outcome.ms,
                   stopped=outcome.stopped, calls=[{"tool": c["tool"], "ms": c["ms"]} for c in outcome.calls])
        logger.info(f"loop act: {act['tool']} after {outcome.steps} steps, {outcome.ms} ms, "
                    f"calls {[c['tool'] for c in outcome.calls]}")
        if act["tool"] == "ask" or act.get("question"):
            await self._say(spoken(act["question"]))
            return
        if act["tool"] != "send" or act.get("waited"):
            # Nothing said yet to send: keep listening. A named agent still
            # takes the stage, so a later "send that" goes there.
            if act.get("waited") and not act.get("notes") and act["target"]["sessionId"] != who.get("sessionId"):
                await self._take_stage(act["target"])
            await self._earcon("listening")
            return
        target, message = act["target"], act["text"]
        if dry_run:
            # Said, not sent: the agent and the words, the start of them when
            # long. The stage does not move and no action is recorded.
            name = "the notes agent" if act.get("notes") else (target.get("name") or target.get("project") or "the agent")
            words = message.split()
            said = " ".join(words[:READ_BACK_WORDS])
            rest = len(words) - READ_BACK_WORDS
            await emit(self, "speaking", voice="manager", text=f"would send: {message}")
            await self._say(spoken(f"To {name}, I'd send: {said}"
                                   + (f" ... and {rest} more words." if rest > 0 else "")))
            return
        if act.get("notes"):
            note(Line(Role.MANAGER, LineKind.ACTION, message, target=target["sessionId"], target_name="Notes"))
            await self._send(target["sessionId"], message, quiet=True)
            await self._say("Noted.")
            return
        if target["sessionId"] != who.get("sessionId"):
            await self._take_stage(target)
        name = target.get("name") or target.get("project") or "the agent"
        await emit(self, "speaking", voice="manager", text=f"message: {message}")
        note(Line(Role.MANAGER, LineKind.ACTION, message, target=target["sessionId"],
                  target_name=target.get("name") or target.get("goal") or name))
        await self._send(target["sessionId"], message)

    async def _take_stage(self, agent: dict):
        """This agent is who the developer is talking to now. The app enrols a
        session the first time you reply to it; naming it by voice is the same
        consent, and a fresh `tbase new` session refuses every send until then."""
        self.stage = agent
        await emit(self, "stage", session=agent["sessionId"], goal=agent.get("goal"),
                   name=agent.get("name"), project=agent.get("project"))
        await effect(_run(TBASE, "enroll", agent["sessionId"], timeout=10))

    async def _do_start_agent(self, text, frame, direction):
        """Defaults, not a chooser: Claude Code in the default project, started
        now, deterministically, so no breath can cancel it. It takes the stage;
        the brief is said, then sent on request like any message."""
        harness = await self._jev.harness(text)
        # Registration is the proof we need; the first send waits for liveness on
        # its own (tbase send defers). --wait-live is left off: until 21 Sep the
        # CLI read it as a directory and every start died in a second.
        argv = [TBASE, "new"] + (["--codex"] if harness == "codex" else [])
        await emit(self, "tool", argv=["tbase", "new"] + argv[2:])
        # Starting an agent is the one thing here that takes long enough to
        # doubt: `tbase new` is allowed seventy-five seconds, and until it
        # returned the room was silent, so there was no way to tell a start
        # that was working from one that had not heard you. Two cues: this one
        # the moment the attempt begins, and "returned" when the agent is
        # actually registered and on stage.
        name = "Codex" if harness == "codex" else "Claude Code"
        await self._earcon("listening")
        await self._say(f"Starting {name}.")
        # Started and staged as one act: a stop mid-start never leaves an
        # agent running that nobody is talking to.
        reg = await effect(self._new_agent(argv, name))
        if not reg:
            await self._earcon("needsYou")
            await self._say("I couldn't start the agent.")
            return
        await self._earcon("returned")
        await self._say(f"Started {name}. Say the brief, then ask me to send it.")

    async def _new_agent(self, argv: list[str], name: str) -> str | None:
        code, out = await _run(*argv, timeout=75)
        reg = next((ln.split(":", 1)[1].strip() for ln in out.splitlines() if ln.startswith("registered:")), None)
        if code != 0 or not reg:
            await emit(self, "tool", argv=["tbase", "new"], exit=code, meaning="failed", text=out[-200:])
            logger.error(f"tbase new failed ({code}): {out[-400:]}")
            return None
        await self._take_stage({"sessionId": reg, "name": name, "project": "", "goal": ""})
        return reg

    async def _notes_session(self) -> dict | None:
        live = {t["sessionId"] for t in await self._targets()}
        # Never a file: the container is shared, and one account's Notes agent
        # is not another's (session.py).
        sid = session.current().notes_sid or ""
        if sid and sid in live:
            return {"kind": "agent", "sessionId": sid, "name": "Notes"}
        await self._say("Starting a notes agent.")
        return await effect(self._new_notes_agent())

    async def _new_notes_agent(self) -> dict | None:
        await emit(self, "tool", argv=["tbase", "new"])
        code, out = await _run(TBASE, "new", timeout=75)
        reg = next((ln.split(":", 1)[1].strip() for ln in out.splitlines() if ln.startswith("registered:")), None)
        if code != 0 or not reg:
            logger.error(f"notes agent: tbase new failed ({code}): {out[-400:]}")
            return None
        session.current().notes_sid = reg
        await _run(TBASE, "enroll", reg, timeout=10)
        await self._send(reg, NOTES_SEED, quiet=True)
        return {"kind": "agent", "sessionId": reg, "name": "Notes"}

    async def _send(self, session_id: str, text: str, quiet: bool = False):
        # A spoken send goes through the app's own Send, so the tray rides
        # with it (hf-12). Quiet sends (notes, seeding) stay on `tbase send`:
        # the developer's tray is not theirs to take.
        meaning = None if quiet else await effect(self._send_through_app(session_id, text))
        if meaning is None:
            code, out = await effect(_run(TBASE, "send", session_id, text))
            meaning = {0: "sent", 2: "not dispatched", 3: "deferred", 4: "ambiguous", 5: "failed"}.get(code, "unknown")
            await emit(self, "tool", argv=["tbase", "send", session_id[:8]], exit=code, meaning=meaning)
            if quiet:
                if code != 0:
                    logger.error(f"quiet send to {session_id[:8]} refused: {meaning}: {out[-200:]}")
                return
        if meaning == "sent":
            await self._earcon("dispatched")
            await self._say(os.getenv("TB_SENT_LINE", "I've sent your message. What's next?"))
        elif meaning == "queued":
            await self._say("It's busy; your message goes in when it finishes.")
        else:
            await self._say(f"Not sent: {meaning}.")

    async def _send_through_app(self, session_id: str, text: str) -> str | None:
        """Wire v1 `send`: what it came to, or None when this Mac does not offer
        it. One idem key per spoken request and never a retry: a send that timed
        out may have landed, so it reads as ambiguous (docs/wire-v1.md)."""
        import wire
        r = await wire.call(wire.Tool.SEND, {"agent": session_id, "text": text}, idem=uuid.uuid4().hex)
        if r is None:
            return None
        if r.get("ok"):
            outcome = (r.get("data") or {}).get("outcome")
            meaning = {"typed": "sent", "queued": "queued", "ambiguous": "ambiguous"}.get(outcome, "not dispatched")
        else:
            code = (r.get("error") or {}).get("code")
            meaning = "ambiguous" if code in ("timeout", "cancelled", "in_progress") else "not dispatched"
        await emit(self, "tool", argv=["send", session_id[:8]], outcome=meaning, wire=True)
        return meaning

    # -- doors ----------------------------------------------------------------------

    async def _say(self, text: str, voice: str = "manager", session: str | None = None,
                   voice_id: str | None = None):
        """The manager's voice, or a session's. Holds the voice lock until the
        speech stops, so nothing else can start talking over it.

        `voice_id` is an ElevenLabs id: the session's own voice, so an agent
        announced down the connection still sounds like that agent rather than
        like the manager. The manager's own id is remembered the first time and
        restored after, so a session never leaves the manager in its voice."""
        async with self._voice:
            if self._tts is not None:
                if self._manager_voice is None:
                    self._manager_voice = self._tts._settings.voice
                await self._tts.use_voice(voice_id or self._manager_voice)
            await emit(self, "speaking", voice=voice, session=session, text=text)
            self._bot_stopped.clear()
            # The synthesizer notes the line when it speaks it (tts.py), so every
            # path the manager's voice takes lands in the transcript exactly once.
            await self.push_frame(TTSSpeakFrame(text))
            try:
                await asyncio.wait_for(self._bot_stopped.wait(), 12.0)
            except TimeoutError:
                pass

    async def _app_speaks(self, url: str, text: str, session_id: str | None = None):
        """A session's line: the card opens on the Mac, the voice comes from here.

        It used to be read aloud by the app, in that session's voice, through
        the app's own speakers. Nothing could cancel that — a canceller removes
        the audio its own renderer played, and the app's synthesiser is not it —
        so the microphone heard every announcement as a person talking. On
        23 Sep at 20:03 the app said "The cutover is complete; we're now
        researching AGI House SF…" and ten seconds later the manager
        transcribed it back as the developer's own words. Three in a row.

        The guards tried first were both worse than the disease: closing the
        microphone while the app read is the deafness the whole transport
        change existed to remove, and matching the transcript against the line
        being read is a string comparison standing in for signal processing.
        Routing the app's audio into the connection's engine broke the shared
        microphone device for everything else on the Mac, dictation included.

        So there is one mouth. The app still opens the card — that is what the
        URL is for — and the line is spoken here, down the same connection the
        manager speaks on, in the session's own ElevenLabs voice. It is in the
        canceller's reference like everything else we play, which is why the
        microphone can stay open through it, and why you can now talk over an
        announcement at all."""
        await effect(_run("open", url))
        await self._say(text, voice="agent", session=session_id,
                        voice_id=await self._voice_for(session_id))

    async def _voice_for(self, session_id: str | None) -> str | None:
        """The ElevenLabs voice this Mac has assigned to a session. Assigned on
        first use, exactly as it was when the app did the speaking, so an agent
        keeps the voice it has always had."""
        if not session_id:
            return None
        code, out = await _run(TBASE, "voice", session_id, "--json")
        # `.get("data")` first: _json_or_text wraps every door's answer as
        # {"exit": code, "data": ...}. Reading "cloud" off the wrapper returns
        # None every time, which is silent — the caller just falls back to the
        # manager's voice, and every agent sounds like the manager. Every other
        # caller in this file unwraps; this one did not, and nothing said so.
        data = _json_or_text(code, out).get("data") or {}
        return (data.get("cloud") if isinstance(data, dict) else None) or None

    async def _earcon(self, name: str):
        await emit(self, "earcon", name=name)  # the app plays it

    async def _targets(self) -> list[dict]:
        code, out = await _run(TBASE, "targets", "--json")
        return _rows(code, out, "the fleet", lambda d: d if isinstance(d, list) else None)

    async def _waiting(self) -> list[dict]:
        code, out = await _run(TBASE, "status", "--json")
        return _rows(code, out, "the waiting list",
                     lambda d: d.get("waiting") if isinstance(d, dict) else None)

    async def _brief(self, session_id: str) -> dict | None:
        code, out = await _run(TBASE, "brief", session_id, "--json")
        data = _json_or_text(code, out).get("data")
        return data if isinstance(data, dict) else None

    async def _live_waiting(self) -> list[dict]:
        """Waiting rows whose session is alive right now, named as the grid names
        them. The store keeps rows for sessions long gone; those are not 'waiting
        on you' in any sense worth saying aloud."""
        live = {t["sessionId"]: t for t in await self._targets()}
        out = []
        for w in await self._waiting():
            t = live.get(w["sessionId"])
            if t:
                out.append({**t, **{k: v for k, v in w.items() if v is not None}})
        return out

    async def _next_session(self) -> dict | None:
        """The next agent WAITING ON YOU, and nothing else.

        Rewritten 28 Sep, after it invited a blue lamp with green ones sitting
        in the grid. Robert: "Control-Option from the grid doesn't open Blue
        Lamp sessions. How are we getting this wrong?"

        By reading the wrong rule. He asked for "the same rules as for the grid
        today, bring next agent", and I took that to `SessionRow.quietRowsLast`
        -- which is how the grid DRAWS rows, five bands deep, blue included.
        But drawing and announcing are different acts. What ⌃⌥ does is
        `announceNext`, and that walks the WAITING rows only: "anything green
        always plays... when every waiting row has been opened, ⌃⌥ WALKS them".
        A working session is drawn on the grid and is never announced from it.

        So there is no fallback any more, and its absence is the fix. The
        version before this one ended `for t in live.values(): return t` --
        invite somebody, anybody, whoever the door listed first. That is how an
        idle session nobody was waiting on took the stage on 27 Sep, and my
        replacement only changed WHICH stranger it picked. Nobody waiting is an
        answer, and the caller already says it out loud.

        Order is `announceNext`'s: unheard first, then the newest of the rest.
        I removed the `heard` term this morning on the grid's authority --
        "hearing a row must not move it" (#439) -- which is a rule about where
        a row is DRAWN, not about what is read aloud next. Restored."""
        current = (self.stage or {}).get("sessionId")
        live = {t["sessionId"] for t in await self._targets()}
        waiting = [w for w in await self._waiting()
                   if w["sessionId"] != current and w["sessionId"] in live]
        if not waiting:
            return None
        waiting.sort(key=lambda w: (w.get("heard", True), -(w.get("eventId") or 0)))
        first = waiting[0]
        rows = {t["sessionId"]: t for t in await self._targets()}
        return {**rows.get(first["sessionId"], {}), **first}

    async def _named_session(self, text: str) -> dict | None:
        """The agent the sentence names, if it names one.

        Added 27 Sep, after "Can you invite the SambaNova agent?" invited
        something else entirely and said nothing about it. The gate classifies
        that as `invite_next` -- there is no invite-by-name intent and there
        does not need to be, because the handler is already given the sentence
        and simply never read it.

        Matching is on the words of the name, not the whole string: an agent
        called "AI Voice Hackathon SambaNova planning" is asked for as "the
        SambaNova agent", and nobody says a callsign in full. A word must be
        four characters or more to count, so "the", "AI" and "agent" cannot
        match, and the agent sharing the most words wins. One match or none;
        two agents tied on the same word is not a name, it is an ambiguity, and
        the queue is a better answer than a coin flip."""
        said = {w.strip(",.!?;:'\"").lower() for w in text.split()}
        said = {w for w in said if len(w) >= 4} - ASKING_WORDS
        if not said:
            # Nothing here but the request itself, so this is the queue and no
            # fleet lookup is needed to know it. Worth the early return rather
            # than a match that fails: `invite_survives_drill` stubs the queue
            # and not the roster, and it hung for as long as this reached past
            # it to shell out for a list it was never going to use.
            return None
        current = (self.stage or {}).get("sessionId")
        best, score = None, 0
        for t in await self._targets():
            if t["sessionId"] == current:
                continue
            words = {w.strip(",.!?;:").lower()
                     for w in f"{t.get('name') or ''} {t.get('project') or ''}".split()}
            hits = len(said & {w for w in words if len(w) >= 4})
            if hits > score:
                best, score = t, hits
            elif hits == score and hits > 0:
                best = None  # a tie names nobody
        if not best:
            return None
        waiting = {w["sessionId"]: w for w in await self._waiting()}
        return {**best, **waiting.get(best["sessionId"], {})}


def _last_user_text(frame: LLMContextFrame) -> str:
    for m in reversed(frame.context.get_messages()):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, str):
                return c
            if isinstance(c, list):
                return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            return ""
    return ""
