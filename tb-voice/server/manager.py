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
import time

import httpx
from loguru import logger
from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    EndWorkerFrame,
    Frame,
    InputTransportMessageFrame,
    LLMContextFrame,
    StartFrame,
    TTSSpeakFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from calls import record
import build_stamp
from events import emit, line
from compose import READBACK_SECS, OpenMessage, classify, continues, filler_only
import session
import span
from vocab import Intent, Line, LineKind, Role, Verdict, line_from_transcript, parse_intent, parse_verdict
from turns import TurnQueue
from spoken import spoken
from tools import _json_or_text, _run

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
SOUNDS = os.getenv("TB_SOUNDS", "")
TBASE = os.getenv("TBASE_BIN", "tbase")
if not os.path.exists(TBASE) and TBASE != "tbase":
    logger.warning(f"TBASE_BIN {TBASE} does not exist; reads will fail closed")

INTENTS: dict[Intent, str] = {
    Intent.INVITE_NEXT: "Invite the next agent or session to speak; 'next agent'; 'who is up'; 'what's next' when no agent is on stage",
    Intent.RUNG_GOAL: "Asks what this project or piece of work is, or what the goal is",
    Intent.RUNG_FINDINGS: "Asks what the agent found or what happened",
    Intent.RUNG_SOLUTION: "Asks for the recommended next step, the solution, or what it proposes",
    Intent.RUNG_WHY: "Asks why, for the rationale or reasoning",
    Intent.CUSTOM: "Any other question about the agent on stage or its work: files, code, status, details, opinions",
    Intent.SEND_MESSAGE: "Tells an agent to do something; a message or instruction to relay",
    Intent.START_AGENT: "Asks to start, spin up, or open a new agent or session",
    Intent.TAKE_NOTE: "Asks to take a note, dictate a note, or put something on the clipboard",
    Intent.SUMMARIZE_RECENT: "Asks what has been going on recently across ALL agents, or what we did today or yesterday; not about one session",
    Intent.TEACH: "Asks what the manager can do, what this is, or how it works",
    Intent.SPEAK: "Tells the manager to say something, speak, respond, answer, or prove it is listening",
    Intent.MUTE: "Tells whoever is talking to stop, pause, be quiet, mute, hold on, or that's enough",
    Intent.NONE: "Addressed but nothing to do: an acknowledgement, a compliment, or filler",
}

# How the transcriber has actually spelled the name, from bot.log. A word that
# starts like one of these, at the start of a turn, is the name; the gate does
# not get to disagree with the person saying it.
NAME_SOUNDS = ("tranq", "trank", "drink", "tranc", "trinq", "tranguil", "tranqu")


def only_the_name(text: str) -> bool:
    """The whole fragment is the manager's name and nothing else. 13:09, 22 Sep:
    "Tranquility." arrived as its own final, was judged alone, and then "Can you
    tell me about your capabilities?" was judged again a second later: two
    verdicts, two answers, from one sentence. A name on its own is never a
    command, whatever punctuation the transcriber put after it."""
    words = [w.strip(",.!?;:").lower() for w in text.split()]
    return len(words) == 1 and words[0].startswith(NAME_SOUNDS)


def names_the_manager(text: str) -> bool:
    """The vocative: the FIRST word sounds like the name and is not 'tranquility
    base' the product. 'Drinkody, can you…' yes; 'let me drink…' no."""
    words = [w.strip(",.!?;:").lower() for w in text.split()[:2]]
    if not words or not words[0].startswith(NAME_SOUNDS):
        return False
    return len(words) < 2 or words[1] != "base"


# Intents that are commands only the manager can carry out. Thinking aloud does
# not produce "invite the next agent"; a clear one of these is addressed even
# without the name.
COMMANDS = {Intent.INVITE_NEXT, Intent.SEND_MESSAGE, Intent.START_AGENT, Intent.TAKE_NOTE,
            Intent.RUNG_GOAL, Intent.RUNG_FINDINGS, Intent.RUNG_SOLUTION, Intent.RUNG_WHY,
            Intent.SUMMARIZE_RECENT, Intent.MUTE}

# Intents that take seconds (a tool run, a model call) before anything is heard.
SLOW_INTENTS = {Intent.SEND_MESSAGE, Intent.SUMMARIZE_RECENT, Intent.CUSTOM, Intent.TEACH, Intent.SPEAK}

# With a session on stage, a confident question about its work is for the manager.
STAGE_QUESTIONS = {Intent.RUNG_GOAL, Intent.RUNG_FINDINGS, Intent.RUNG_SOLUTION, Intent.RUNG_WHY,
                   Intent.CUSTOM, Intent.SEND_MESSAGE}

# Jev's answer to "Send to X?" (a yes/no/other choice), parsed at the boundary.
CONFIRM_ANSWER = {"yes": Verdict.SEND, "no": Verdict.HOLD}

RUNG_FOR = {Intent.RUNG_GOAL: "goal", Intent.RUNG_FINDINGS: "findings",
            Intent.RUNG_SOLUTION: "solution", Intent.RUNG_WHY: "why"}


class JevClient:
    def __init__(self, api_key: str):
        self._client = httpx.AsyncClient(
            headers={"Authorization": f"Bearer {api_key}"}, timeout=8.0)

    last: dict = {}

    async def ask(self, state: dict, questions: dict) -> dict:
        t0 = time.monotonic()
        r = await self._client.post(
            JEV_URL, json={"state": state, "model": "jev-latest", "questions": questions})
        r.raise_for_status()
        answers = r.json()["answers"]
        ms = int((time.monotonic() - t0) * 1000)
        self.last = {"state": state, "questions": list(questions), "answers": answers, "ms": ms}
        record("jev", {"state": state, "model": "jev-latest", "questions": questions}, r.json(), ms=ms)
        return answers

    async def turn(self, utterance: str, recent: list[str], stage: dict | None):
        ctx = (f"The assistant is a voice manager named {NAME}. It listens to a developer "
               "thinking aloud while supervising a fleet of coding agents, and speaks only "
               "when addressed. Lines marked 'you' are the developer; other lines were spoken "
               "by the assistant or by an agent, and the developer heard them.")
        state = {
            "context": ctx,
            "conversation_before": [
                {"who": ln.jev_who, "status": ln.jev_status, "text": ln.jev_text} for ln in session.current().exchange[-8:]
            ],
            "agent_on_stage": (stage or {}).get("goal"),
            "text_to_judge": utterance,
            "rules": (
                "Judge ONLY text_to_judge. conversation_before is context: 'you' is the developer, "
                "other names are the assistant or an agent speaking; a status of 'acted' or 'spoken' "
                "means that turn was already handled and must not be acted on again. "
                f"The transcriber often misspells the name {NAME}: Drinkody, Tranquillity, Tranquilly, "
                "Tranquil, Trank; a turn opening with such a word is addressed."),
        }
        answers = await self.ask(state, {
            "addressed": {"type": "noul",
                "instructions": (f"In text_to_judge, is the developer asking the assistant {NAME} to speak "
                                 "or act RIGHT NOW? Earlier turns do not count; only this text."),
                "criteria": {"true": (f"Names {NAME}, or asks or instructs the assistant directly"
                                      + (", or asks about the agent on stage: its goal, findings, next step, reasons, or tells it to do something"
                                         if stage else "")),
                             "false": ("Thinking aloud, a rhetorical question, talking to another "
                                       f"person, reading text aloud, or the word {NAME.lower()} used for something else")}},
            "intent": {"type": "choice",
                "instructions": "If text_to_judge is a request to the assistant, which kind is it?",
                "criteria": {i.value: d for i, d in INTENTS.items()}},
        })
        return float(answers["addressed"]["noul"]), answers["intent"]

    async def target(self, utterance: str, candidates: list[dict]) -> dict:
        crit = {c["sessionId"]: f"{c.get('name') or ''}: {c.get('goal') or c.get('topic') or c['project']}" for c in candidates}
        answers = await self.ask(
            {"utterance": utterance, "sessions": crit},
            {"target": {"type": "choice",
                        "instructions": "Which session is this message meant for, judged by its goal?",
                        "criteria": crit}})
        return answers["target"]

    async def is_action(self, utterance: str, stage_name: str) -> float:
        """A request about the session on stage: is it asking the session to DO
        something, or asking about its work? An action is typed in; a question is
        answered from the record. 17:21: 'can you open that in the browser?' was
        answered with a promise the brain could not keep."""
        answers = await self.ask(
            {"agent_on_stage": stage_name, "text_to_judge": utterance},
            {"action": {"type": "noul",
                        "instructions": "Is the developer asking the agent on stage to perform an action (open, run, create, change, send, fix, deploy, show), rather than asking a question about its work?",
                        "criteria": {"true": "An instruction or request for the agent to do something",
                                     "false": "A question about what the agent did, found, proposes, or why"}}})
        return float(answers["action"]["noul"])

    async def compose(self, utterance: str, draft_tail: str, destination: str) -> dict:
        """While a message is open: is this turn more of the message, or a word
        about the message? Only a confident send/cancel/retarget acts; the rest
        is content, which is the safe default."""
        answers = await self.ask(
            {"context": f"The developer is dictating a message to {destination}. It will be sent "
                        "only when they say so. The turn may be more of the message, or an "
                        "instruction about the message itself.",
             "message_so_far": draft_tail, "turn": utterance},
            {"kind": {"type": "choice", "instructions": "What is this turn?",
                      "criteria": {"content": "More of the message being dictated",
                                   "send": "Says the message is finished and should be sent now",
                                   "hold": "Says not to send yet, wait, or that they are still thinking",
                                   "cancel": "Says to drop, discard, or forget the message",
                                   "retarget": "Says the message should go to a different agent or place"}}})
        return answers["kind"]

    async def confirm(self, utterance: str, question: str) -> dict:
        answers = await self.ask(
            {"question_asked": question, "reply": utterance},
            {"answer": {"type": "choice", "instructions": "How did the speaker answer?",
                        "criteria": {"yes": "Agrees, confirms, go ahead",
                                     "no": "Declines, 'not that one', a different target",
                                     "other": "Unrelated, or talking to someone else"}}})
        return answers["answer"]


TRANSCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "transcript.md")
NOTES_STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "notes-session.txt")
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
    event, numbered, so the app holds the full record: every other event that
    carries the user's words is cut to 120 characters, and hosted there is no
    transcript on disk at all (hf-20)."""
    s = session.current()
    ln = Line(ln.role, ln.kind, ln.text.strip(), ln.speaker, ln.target, ln.target_name)
    s.exchange.append(ln)
    del s.exchange[:-session.EXCHANGE_KEEP]
    s.said += 1
    rec = line("said", n=s.said, **ln.said_fields())
    if os.getenv("TB_HOSTED"):
        from wire import outbox
        outbox().put_nowait(rec)
        return  # no transcript on disk where the bot is hosted; the app keeps the `said` lines
    with open(TRANSCRIPT, "a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {ln.jev_who} [{ln.jev_status}]: {ln.jev_text}\n")


def seed_exchange():
    """Local only: a restart picks up where the transcript left off. Hosted there
    is no transcript, and a new session must start empty."""
    if os.getenv("TB_HOSTED"):
        return
    s = session.current()
    try:
        with open(TRANSCRIPT) as f:
            for raw in f.readlines()[-session.EXCHANGE_KEEP:]:
                parts = raw.rstrip("\n").split("  ", 1)
                if len(parts) != 2 or ": " not in parts[1]:
                    continue
                head, text = parts[1].split(": ", 1)
                who, _, status = head.partition(" [")
                s.exchange.append(line_from_transcript(who, status.rstrip("]"), text))
    except FileNotFoundError:
        pass


def exchange_lines(n: int = 8) -> list[str]:
    return [f"{ln.jev_who} ({ln.jev_status}): {ln.jev_text}" for ln in session.current().exchange[-n:]]


def _chosen(choice: dict) -> str:
    # A Jev choice answer: {"choice": name, "confidence": c, "probabilities": {name: p}}.
    probs = choice.get("probabilities") or {}
    return choice.get("choice") or (max(probs.items(), key=lambda kv: kv[1])[0] if probs else "none")


class Brain:
    """One completion, no tools: the answer to a question about the session on
    stage, from its brief and last message. MiniMax M2.7 on General Compute."""

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
    def transcript_tail(path: str | None, limit: int = 7000) -> str:
        """The last stretch of the session's own transcript: what it and its
        supervisor actually said, text parts only."""
        if not path or not os.path.exists(path):
            return ""
        parts = []
        try:
            with open(path, "rb") as f:
                f.seek(max(0, os.path.getsize(path) - 400_000))
                for raw in f.read().decode(errors="replace").splitlines():
                    try:
                        o = json.loads(raw)
                    except Exception:
                        continue
                    if o.get("type") not in ("assistant", "user"):
                        continue
                    c = (o.get("message") or {}).get("content")
                    if isinstance(c, str):
                        parts.append(f"{o['type']}: {c}")
                    elif isinstance(c, list):
                        txt = " ".join(p.get("text", "") for p in c if isinstance(p, dict) and p.get("type") == "text")
                        if txt.strip():
                            parts.append(f"{o['type']}: {txt}")
        except Exception as e:
            logger.warning(f"transcript read failed: {e}")
        return "\n".join(parts)[-limit:]

    async def tail(self, brief: dict, sid: str | None) -> str:
        """The agent's own words. Hosted the file is on the Mac, not here: the
        path in the brief never existed in the container and this returned
        nothing, silently, for every hosted answer (hf-4). The Mac reads it."""
        if os.getenv("TB_HOSTED") and sid:
            import wire
            r = await wire.call(wire.Tool.TRANSCRIPT, {"agent": sid, "chars": 7000})
            if r is not None:
                if not r.get("ok"):
                    logger.warning(f"transcript for {sid[:8]}: {(r.get('error') or {}).get('code')}")
                    return ""
                turns = (r.get("data") or {}).get("turns") or []
                return "\n".join(f"{t.get('who')}: {t.get('text')}" for t in turns)[-7000:]
            logger.warning("transcript: this Mac offers no transcript tool; answering from the brief alone")
        return self.transcript_tail(brief.get("transcriptPath"))

    async def answer(self, question: str, brief: dict, recent: list[str], sid: str | None = None) -> str:
        facts = {k: brief.get(k) for k in ("goal", "recap", "proposal", "findings", "solution", "why", "lastAssistantMessage")}
        tail = await self.tail(brief, sid)
        msgs = [
            {"role": "system", "content": (
                "You are a coding-agent session answering its supervisor aloud, in first person "
                "plural ('we'). Answer ONLY from the facts given. One or two sentences, 30 words "
                "max, no lists, no markdown. If the facts do not say, say so in one sentence. "
                "Spoken, so never say an id, hash, path, URL, branch or file name; say 'the file', "
                "'the branch', 'the PR', 'PR five forty-seven'. You answer questions; you cannot perform "
                "actions and must never claim to (no 'opening', 'sending', 'doing it now').")},
            {"role": "user", "content": f"Facts about this session:\n{json.dumps(facts, ensure_ascii=False)}\n\n"
                                        f"The end of the session's transcript:\n{tail}\n\n"
                                        f"The exchange so far (you = the supervisor):\n" + "\n".join(exchange_lines()) + f"\n\nQuestion: {question}"},
        ]
        body = {"model": self.model, "messages": msgs, "max_tokens": 400, "temperature": 0.3}
        t0 = time.monotonic()
        r = await self._client.post("/chat/completions", json=body)
        r.raise_for_status()
        record("brain", body, r.json(), ms=int((time.monotonic() - t0) * 1000))
        text = (r.json()["choices"][0]["message"].get("content") or "").strip()
        return " ".join(text.split())[:600]


    async def plain(self, question: str, exchange: list[str]) -> str:
        """One tool-free answer as the manager itself: who it is, what this is."""
        from prompt import SYSTEM
        msgs = [
            {"role": "system", "content": SYSTEM + "\nAnswer in one sentence, 30 words max, spoken aloud."},
            {"role": "user", "content": "Exchange so far:\n" + "\n".join(exchange) + f"\n\nQuestion: {question}"},
        ]
        body = {"model": self.model, "messages": msgs, "max_tokens": 400, "temperature": 0.3}
        t0 = time.monotonic()
        r = await self._client.post("/chat/completions", json=body)
        r.raise_for_status()
        record("brain", body, r.json(), ms=int((time.monotonic() - t0) * 1000))
        return " ".join(((r.json()["choices"][0]["message"].get("content") or "")).split())

    async def readback(self, text: str) -> str:
        """Twenty words of what was dictated, for the one read-back after silence."""
        msgs = [
            {"role": "system", "content": (
                "Summarize the dictated message below in at most 20 words, spoken aloud, plain "
                "words, no preamble, no quotes, no ids. Keep the concrete nouns.")},
            {"role": "user", "content": text[-4000:]},
        ]
        body = {"model": self.model, "messages": msgs, "max_tokens": 120, "temperature": 0.2}
        t0 = time.monotonic()
        r = await self._client.post("/chat/completions", json=body)
        r.raise_for_status()
        record("brain", body, r.json(), ms=int((time.monotonic() - t0) * 1000))
        words = ((r.json()["choices"][0]["message"].get("content") or "")).split()
        return " ".join(words[:20]).rstrip(".")

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
    def __init__(self, jev: JevClient):
        super().__init__()
        self._jev = jev
        self._brain = Brain()
        seed_exchange()
        self._recent: list[str] = []
        self._last_intent: Intent | None = None
        # Each intent's handler, named once. Found by building "_do_<label>"
        # before hf-26: a renamed label was not an error, only a handler that
        # silently never ran. SUMMARIZE_RECENT has none: it goes to the LLM.
        self._handlers = {
            Intent.MUTE: self._do_mute, Intent.NONE: self._do_none,
            Intent.INVITE_NEXT: self._do_invite_next,
            Intent.RUNG_GOAL: self._do_rung_goal, Intent.RUNG_FINDINGS: self._do_rung_findings,
            Intent.RUNG_SOLUTION: self._do_rung_solution, Intent.RUNG_WHY: self._do_rung_why,
            Intent.CUSTOM: self._do_custom, Intent.TEACH: self._do_teach, Intent.SPEAK: self._do_speak,
            Intent.SEND_MESSAGE: self._do_send_message, Intent.START_AGENT: self._do_start_agent,
            Intent.TAKE_NOTE: self._do_take_note,
        }
        self._last_intent_at = 0.0
        self.stage: dict | None = None
        self.open: OpenMessage | None = None  # dictation with a destination (compose.py)
        self._wire_task = None  # hosted: drains wire.outbox into transport messages
        self._idle_task = None  # hosted: ends the session after IDLE_SECS without speech
        self._last_heard = time.monotonic()
        self._readback_task: asyncio.Task | None = None
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

    async def _say_and_wait(self, text: str, timeout: float = 8.0):
        await self._say(text)  # _say already waits for its own voice to stop

    async def _drain_wire(self):
        """Hosted: every event line and door request becomes a text frame on the
        socket, pushed from inside the pipeline so ordering holds."""
        from pipecat.frames.frames import OutputTransportMessageUrgentFrame
        from wire import outbox
        q = outbox()
        while True:
            msg = await q.get()
            await self.push_frame(OutputTransportMessageUrgentFrame(message=msg))

    async def _end_when_idle(self):
        started = time.monotonic()
        while True:
            now = time.monotonic()
            idle_in = IDLE_SECS - (now - self._last_heard)
            rotate_in = SESSION_LIFE_SECS - (now - started)
            if idle_in > 0 and rotate_in > 0:
                await asyncio.sleep(min(idle_in, rotate_in, 30))
                continue
            busy = self.open is not None or self._user_speaking
            if busy:  # mid-message or mid-sentence: look again shortly
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
        for name in ("_wire_task", "_idle_task"):
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
            if os.getenv("TB_HOSTED") and self._wire_task is None:
                self._wire_task = self.create_task(self._drain_wire())
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
        if self.open is not None:
            # Dictation: every word is the message. No hold, no gate, no Jev
            # intent. Queued like any turn; _dispatch routes it when reached.
            self._turns.put((text, frame, direction))
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
        self.heard += 1
        self._turns.put((text, frame, direction))
        self._recent.append(text)

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
            self.heard += 1
            self._turns.put((text, frame, direction))
            self._recent.append(text)

    async def _dispatch(self, turn: tuple):
        """One turn, when every turn before it has finished. Whether it is
        dictation is read NOW: the turn before may have just opened a message."""
        text, frame, direction = turn
        if self.open is not None:
            await self._compose_turn(text, frame, direction)
        else:
            await self._handle_turn(text, frame, direction)

    async def _handle_turn(self, text, frame, direction):
        try:
            await self._turn(text, frame, direction)
        except FileNotFoundError as e:  # a read door is missing: say so, never infer
            logger.error(f"manager read failed: {e}")
            await emit(self, "error", reason=str(e)[:160])
            await self._say("I can't read the fleet right now.")
        except Exception as e:  # the manager fails closed: silence, never a crash
            logger.exception(f"manager turn failed: {e}")
            await emit(self, "error", reason=str(e)[:160])

    async def _turn(self, text, frame, direction):
        t0 = time.monotonic()
        p, intent_answer = await self._jev.turn(text, self._recent, self.stage)
        ms = int((time.monotonic() - t0) * 1000)
        intent = parse_intent(_chosen(intent_answer))
        if not self.stage and intent in RUNG_FOR:
            # "What's next?" with nobody on stage is the ⌃⌥ question: the next
            # agent's update, not a lecture about the stage being empty.
            intent = Intent.INVITE_NEXT
        raw_p = p
        rule = None
        if names_the_manager(text):
            p, rule = max(p, 0.95), "named"  # the transcriber's spelling is not a veto
        elif intent in COMMANDS and float(intent_answer.get("confidence", 0)) >= 0.9 and p >= 0.3:
            p, rule = max(p, 0.6), "fleet command"  # nobody else can execute it
        elif (self.stage and intent in STAGE_QUESTIONS
              and float(intent_answer.get("confidence", 0)) >= 0.8 and p >= 0.3):
            p, rule = max(p, 0.6), "about the stage"  # a question about the work on stage
        await emit(self, "jev", ms=self._jev.last.get("ms"), state=self._jev.last.get("state"),
                   answers=self._jev.last.get("answers"), raw_p=round(raw_p, 2), rule=rule)
        speak = p >= THRESHOLD
        logger.info(f"gate p={p:.2f} {intent.value} {ms}ms {'SPEAK' if speak else 'silent'} :: {text[:80]}")
        note(Line(Role.USER, LineKind.COMMAND if speak else LineKind.TALK, text))
        await emit(self, "addressed" if speak else "listening",
                   p=round(p, 2), intent=intent.value if speak else None, ms=ms, text=text[:120])
        if not speak:
            return
        # One sentence, one action. 02:58, 22 Sep: "Okay, can you invite the
        # next" and "agent to speak, please?" arrived half a second apart, both
        # were judged invite_next, and two agents were invited. The hold joins
        # what it can; this catches what it cannot.
        now = time.monotonic()
        if intent == self._last_intent and now - self._last_intent_at < REPEAT_SECS:
            logger.info(f"dropping a second {intent.value} {now - self._last_intent_at:.1f}s after the first")
            await emit(self, "listening", p=round(p, 2), ms=ms, text=text[:120])
            return
        self._last_intent, self._last_intent_at = intent, now
        self.addressed += 1
        # The activation cue covers latency you would otherwise fill by repeating
        # yourself. An invite or a rung speaks within a second; a cue there lands
        # on top of the voice. Only the slow intents get one.
        if intent in SLOW_INTENTS:
            await self._earcon("listening")
        handler = self._handlers.get(intent)
        if handler:
            await handler(text, frame, direction)
        else:
            await self._llm(frame, direction, text, intent)

    # -- intents handled without the LLM ---------------------------------------------

    async def _do_mute(self, text, frame, direction):
        """Stop whoever is talking: the app's voice via the mute verb, and the
        manager's own by not saying anything."""
        await emit(self, "tool", argv=["open", f"{SCHEME}://mute"])
        await _run("open", f"{SCHEME}://mute")

    async def _do_none(self, text, frame, direction):
        pass  # the activation cue already played; nothing to add

    async def _do_invite_next(self, text, frame, direction):
        nxt = await self._next_session()
        if not nxt:
            await self._say("Nobody is waiting, and I see no live sessions.")
            return
        self.stage = nxt
        await emit(self, "stage", session=nxt["sessionId"], goal=nxt.get("goal"),
                   name=nxt.get("name"), project=nxt.get("project"))
        who = nxt.get("name") or nxt.get("project") or "the next agent"
        await self._say_and_wait(f"Inviting {who} to speak.")
        await asyncio.sleep(0.2)  # a breath between the manager's voice and the agent's
        brief = await self._brief(nxt["sessionId"])
        spoken = " ".join(x for x in ((brief or {}).get("recap"), (brief or {}).get("proposal")) if x)
        await emit(self, "speaking", voice="agent", session=nxt["sessionId"], text=spoken)
        note(Line(Role.AGENT, LineKind.SPOKEN, spoken or "(no brief stored)",
                  speaker=nxt.get("name") or nxt.get("goal") or nxt["sessionId"][:8]))
        await self._app_speaks(f"{SCHEME}://hear?session={nxt['sessionId']}", spoken or "x " * 20)

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
        await self._app_speaks(f"{SCHEME}://rung?session={self.stage['sessionId']}&kind={kind}", rung["spoken"])

    async def _do_custom(self, text, frame, direction):
        if not self.stage:
            await self._llm(frame, direction, text, "custom")
            return
        # An instruction to the session on stage is typed in; a question is answered.
        try:
            p_action = await self._jev.is_action(text, self.stage.get("name") or self.stage.get("goal") or "")
        except Exception as e:
            logger.warning(f"is_action failed: {e}")
            p_action = 0.0
        if p_action >= 0.5:
            await emit(self, "addressed", p=1.0, intent=Intent.SEND_MESSAGE.value, ms=0, text=text[:120])
            await self._do_send_message(text, frame, direction)
            return
        await self._answer_about_stage(text, await self._brief(self.stage["sessionId"]))

    async def _answer_about_stage(self, question: str, brief: dict | None):
        """A question about the session on stage: one completion from its brief,
        spoken by the session. No tools; nothing to wander off into."""
        from urllib.parse import quote
        sid = self.stage["sessionId"]
        if not brief:
            await self._say("That session has no brief stored yet.")
            return
        try:
            answer = await self._brain.answer(question, brief, self._recent, sid)
        except Exception as e:
            logger.error(f"brain failed: {e}")
            await emit(self, "error", reason=f"brain: {str(e)[:120]}")
            await self._say("I couldn't get an answer from the session's notes.")
            return
        if not answer:
            await self._say("The session's notes don't say.")
            return
        answer = spoken(answer)
        await emit(self, "speaking", voice="agent", session=sid, text=answer[:160])
        note(Line(Role.AGENT, LineKind.SPOKEN, answer, speaker=self.stage.get("name") or self.stage.get("goal") or sid[:8]))
        await self._app_speaks(f"{SCHEME}://say?session={sid}&text={quote(answer)}", answer)

    CAPABILITIES = ("Say what's next to hear the next agent. Ask for the goal, findings, next step "
                    "or why. Say tell it to, then your message. Say stop to mute. Say start an agent.")

    async def _do_teach(self, text, frame, direction):
        """Teach without a tool-choosing model: showing means reading the fleet
        aloud, controls are a fixed line, and 'what is this' is one plain answer."""
        low = text.lower()
        if any(w in low for w in ("show", "see", "session", "agent", "who is", "who's", "what's going on", "waiting")):
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
            return
        if any(w in low for w in ("control", "what can you", "how do i", "commands", "what do you do",
                                  "capabilit", "who are you", "what are you", "about you")):
            await self._say(self.CAPABILITIES)
            return
        try:
            answer = await self._brain.plain(text, exchange_lines())
        except Exception as e:
            logger.error(f"teach failed: {e}")
            answer = ""
        await self._say(answer or "I'm Tranquility, the hands-free manager for your coding agents. " + self.CAPABILITIES)

    async def _do_speak(self, text, frame, direction):
        """Told to speak: one sentence about where things stand, then a door."""
        low = text.lower()
        if any(w in low for w in ("who are you", "what are you", "explain", "yourself", "introduce")):
            await self._do_teach(text, frame, direction)
            return
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
        if self.stage:
            # The stage is the target. Compose from the developer's words and send;
            # no tool-choosing model in the loop to ask which project.
            name = self.stage.get("name") or self.stage.get("project") or "the agent"
            try:
                message = await self._span_message(text, name, self.stage.get("goal"))
            except Exception as e:
                logger.error(f"span pick failed: {e}")
                await emit(self, "error", reason=f"span: {str(e)[:120]}")
                message = None  # nothing picked is nothing sent: keep listening
            if not message:
                await self._open({"kind": "agent", "sessionId": self.stage["sessionId"],
                                  "name": self.stage.get("name") or self.stage.get("project") or "the agent"})
                return
            await emit(self, "speaking", voice="manager", text=f"message: {message[:160]}")
            note(Line(Role.MANAGER, LineKind.ACTION, message, target=self.stage["sessionId"],
                      target_name=self.stage.get("name") or self.stage.get("goal") or "the stage"))
            await self._send(self.stage["sessionId"], message)
            return
        live = await self._targets()
        if not live:
            await self._say("I see no live sessions to send to.")
            return
        # The destination is settled at the door: named once, before a word is
        # spent, so a wrong pick costs one clause ("no, the planning one") and
        # never a list. The message itself is dictated after.
        choice = await self._jev.target(text, live)
        sid = _chosen(choice)
        c = next((x for x in live if x["sessionId"] == sid), live[0])
        self.stage = c
        await emit(self, "stage", session=c["sessionId"], goal=c.get("goal"), name=c.get("name"), project=c.get("project"))
        try:
            seed = await self._span_message(text, c.get("name") or c.get("project") or "the agent", c.get("goal")) or ""
        except Exception as e:
            logger.error(f"span pick failed: {e}")
            seed = ""
        await self._open({"kind": "agent", "sessionId": c["sessionId"],
                          "name": c.get("name") or c.get("project") or "the agent"}, seed=seed)

    async def _span_message(self, request: str, agent: str, goal: str | None) -> str | None:
        """The developer's own words for this send, copied, or None when there
        is nothing to send yet (span.py)."""
        cands = await span.candidates()
        answer = await self._brain.pick_span(request, cands, agent, goal)
        pick = span.check(answer, cands, request)
        logger.info(f"span: {len(cands)} candidate lines; answer {answer}; pick {pick}")
        return span.text_of(pick, cands) if pick else None

    async def _do_start_agent(self, text, frame, direction):
        """Defaults, not a chooser: Claude Code in the default project, started
        now, deterministically, so no breath can cancel it. Then the door opens
        and the brief is dictated to it."""
        harness = "codex" if "codex" in text.lower() else "claude"
        # Registration is the proof we need; the first send waits for liveness on
        # its own (tbase send defers). --wait-live is left off: until 21 Sep the
        # CLI read it as a directory and every start died in a second.
        argv = [TBASE, "new"] + (["--codex"] if harness == "codex" else [])
        await emit(self, "tool", argv=["tbase", "new"] + argv[2:])
        code, out = await _run(*argv, timeout=75)
        reg = next((ln.split(":", 1)[1].strip() for ln in out.splitlines() if ln.startswith("registered:")), None)
        if code != 0 or not reg:
            await emit(self, "tool", argv=["tbase", "new"], exit=code, meaning="failed", text=out[-200:])
            logger.error(f"tbase new failed ({code}): {out[-400:]}")
            await self._say("I couldn't start the agent.")
            return
        name = "Codex" if harness == "codex" else "Claude Code"
        self.stage = {"sessionId": reg, "name": name, "project": "", "goal": ""}
        await emit(self, "stage", session=reg, name=name)
        await self._open({"kind": "agent", "sessionId": reg, "name": name},
                         line=f"Started {name}. What would you like to say?")

    async def _do_take_note(self, text, frame, direction):
        """Notes are a destination like any agent: a session named Notes that
        keeps notes.md and notes.html in its own hub directory. Found by the id
        in notes-session.txt while it is live; started (and seeded once) when
        it is not. No writer, no file format, no new door."""
        dest = await self._notes_session()
        if not dest:
            await self._say("I couldn't start the notes agent.")
            return
        await self._open(dest, line="Noting. Go ahead.")

    async def _notes_session(self) -> dict | None:
        live = {t["sessionId"] for t in await self._targets()}
        hosted = bool(os.getenv("TB_HOSTED"))
        if hosted:
            # Never a file where the bot is hosted: the container is shared, and
            # one account's Notes agent is not another's (session.py).
            sid = session.current().notes_sid or ""
        else:
            try:
                sid = open(NOTES_STATE).read().strip()
            except FileNotFoundError:
                sid = ""
        if sid and sid in live:
            return {"kind": "agent", "sessionId": sid, "name": "Notes"}
        await self._say("Starting a notes agent.")
        await emit(self, "tool", argv=["tbase", "new"])
        code, out = await _run(TBASE, "new", timeout=75)
        reg = next((ln.split(":", 1)[1].strip() for ln in out.splitlines() if ln.startswith("registered:")), None)
        if code != 0 or not reg:
            logger.error(f"notes agent: tbase new failed ({code}): {out[-400:]}")
            return None
        if hosted:
            session.current().notes_sid = reg
        else:
            with open(NOTES_STATE, "w") as f:
                f.write(reg + "\n")
        await _run(TBASE, "enroll", reg, timeout=10)
        await self._send(reg, NOTES_SEED, quiet=True)
        return {"kind": "agent", "sessionId": reg, "name": "Notes"}

    # -- the open message ------------------------------------------------------------

    async def _open(self, destination: dict, line: str | None = None, seed: str = ""):
        if destination.get("sessionId"):
            # The app enrols a session the first time you reply to it: your
            # confirmed send is the consent. Naming it as a destination by voice
            # is the same consent, so the door enrols (idempotent). Without it a
            # fresh `tbase new` session refuses every send: "not enrolled".
            await _run(TBASE, "enroll", destination["sessionId"], timeout=10)
        self.open = OpenMessage(destination)
        if seed and len(seed.split()) > 2:
            self.open.append(seed)
        await self._earcon("listening")
        await self._say(line or f"For {self.open.name}. Go ahead.")
        await self._show_draft()
        self._arm_readback()

    async def _show_draft(self):
        if not self.open:
            return
        tail = self.open.text[-140:]
        await emit(self, "speaking", voice="draft", session=self.open.destination.get("sessionId"),
                   text=f"for {self.open.name}: {tail}" if tail else f"for {self.open.name}")

    def _arm_readback(self):
        if self._readback_task:
            self._readback_task.cancel()
        self._readback_task = asyncio.create_task(self._readback_after_silence())

    async def _readback_after_silence(self):
        """One read-back after READBACK_SECS of silence, then wait for the word.
        Never a second one until more has been said; never while speech is live."""
        try:
            await asyncio.sleep(READBACK_SECS)
        except asyncio.CancelledError:
            return
        m = self.open
        if not m or m.asked or not m.text:
            return
        try:
            summary = await self._brain.readback(m.text)
        except Exception as e:
            logger.error(f"readback failed: {e}")
            summary = " ".join(m.text.split()[:20])
        m.asked = True
        await self._say(f"I heard: {summary}. Send to {m.name}?")

    async def _compose_turn(self, text, frame, direction):
        m = self.open
        if not m:
            return
        verdict, remainder = classify(text, previous=m.last)
        if verdict is Verdict.CONTENT and continues(m.last):
            pass  # a continuation is content, whatever it sounds like alone
        elif verdict is Verdict.CONTENT and m.asked:
            # After the read-back, a short reply is an answer to "send?".
            if len(text.split()) <= 6:
                verdict = CONFIRM_ANSWER.get(_chosen(await self._jev.confirm(text, f"Send to {m.name}?")),
                                             Verdict.CONTENT)
            if verdict is not Verdict.CONTENT:
                remainder = ""  # the answer is not part of the message
        if verdict is Verdict.CONTENT and not continues(m.last) and len(text.split()) <= 12:
            # Short, complete, and not a known phrase: let Jev say whether it is about the message.
            k = await self._jev.compose(text, m.text[-600:], m.name)
            judged = parse_verdict(_chosen(k))
            if float(k.get("confidence", 0)) >= 0.85 and judged is not Verdict.CONTENT:
                verdict, remainder = judged, ""
        await emit(self, "listening" if verdict is Verdict.CONTENT else "addressed",
                   p=1.0, intent=f"compose:{verdict.value}", ms=0, text=text[:120])
        if verdict is Verdict.CONTENT:
            if filler_only(text):
                return  # a breath the segmenter cut out; not part of the message
            if m.append(text):
                note(Line(Role.USER, LineKind.DICTATION, text))
                await self._show_draft()
            self._arm_readback()
            return
        if verdict is Verdict.HOLD:
            note(Line(Role.USER, LineKind.COMMAND, text))
            m.asked = True  # no second read-back until more is said
            return
        if verdict is Verdict.CANCEL:
            note(Line(Role.USER, LineKind.COMMAND, text))
            await self._close()
            await self._say("Dropped.")
            return
        if verdict is Verdict.RETARGET:
            note(Line(Role.USER, LineKind.COMMAND, text))
            live = await self._targets()
            if live:
                choice = await self._jev.target(text, live)
                sid = _chosen(choice)
                c = next((x for x in live if x["sessionId"] == sid), None)
                if c:
                    self.stage = c
                    m.destination = {"kind": "agent", "sessionId": c["sessionId"],
                                     "name": c.get("name") or c.get("project") or "the agent"}
                    await _run(TBASE, "enroll", c["sessionId"], timeout=10)  # same consent as the door
                    await self._say(f"For {m.name}. Go ahead.")
                    await self._show_draft()
                    self._arm_readback()
                    return
            await self._say("I couldn't find that one. Say the project name.")
            return
        # send
        if remainder:
            m.append(remainder)
            note(Line(Role.USER, LineKind.DICTATION, remainder))
        note(Line(Role.USER, LineKind.COMMAND, text))
        await self._deliver()

    async def _deliver(self):
        m = self.open
        if not m or not m.text.strip():
            await self._say("There's nothing to send yet.")
            return
        text, dest = m.text.strip(), m.destination
        await self._close()
        note(Line(Role.MANAGER, LineKind.ACTION, text, target=dest.get("sessionId"), target_name=dest.get("name")))
        await self._send(dest["sessionId"], text)

    async def _close(self):
        if self._readback_task:
            self._readback_task.cancel()
            self._readback_task = None
        self.open = None
        await emit(self, "quiet")

    async def _send(self, session_id: str, text: str, quiet: bool = False):
        code, out = await _run(TBASE, "send", session_id, text)
        meaning = {0: "sent", 2: "not dispatched", 3: "deferred", 4: "ambiguous", 5: "failed"}.get(code, "unknown")
        await emit(self, "tool", argv=["tbase", "send", session_id[:8]], exit=code, meaning=meaning)
        if quiet:
            if code != 0:
                logger.error(f"quiet send to {session_id[:8]} refused: {meaning}: {out[-200:]}")
            return
        if code == 0:
            await self._earcon("dispatched")
            await self._say(os.getenv("TB_SENT_LINE", "I've sent your message. What's next?"))
        else:
            await self._say(f"Not sent: {meaning}.")

    async def _llm(self, frame, direction, text, intent, brief=None):
        note = {"intent": intent.value, "stage": self.stage and {
            "sessionId": self.stage["sessionId"], "goal": self.stage.get("goal"),
            "project": self.stage.get("project")}}
        if self.stage and intent is Intent.CUSTOM:
            brief = brief or await self._brief(self.stage["sessionId"])
            if brief:
                note["brief"] = {k: brief.get(k) for k in ("goal", "recap", "proposal", "findings", "solution", "why", "lastAssistantMessage")}
                note["instruction"] = "Answer the question from this brief in the session's own voice via say_as_session, 30 words max."
        if intent is Intent.SEND_MESSAGE and self.stage:
            note["instruction"] = ("Call send_message with the stage sessionId now; do not ask "
                                   "which session. Then confirm in one clause.")
        if intent is Intent.SUMMARIZE_RECENT:
            note["recent"] = await self._recent_briefs()
        frame.context.add_message({"role": "developer", "content": "manager note: " + json.dumps(note)})
        await emit(self, "speaking", intent=intent.value, stage=(self.stage or {}).get("goal"))
        await self.push_frame(frame, direction)

    # -- doors ----------------------------------------------------------------------

    async def _say(self, text: str, voice: str = "manager", session: str | None = None):
        """The manager's voice. Holds the voice lock until its own speech stops,
        so nothing else can start talking over it."""
        async with self._voice:
            await emit(self, "speaking", voice=voice, session=session, text=text)
            self._bot_stopped.clear()
            # The synthesizer notes the line when it speaks it (tts.py), so every
            # path the manager's voice takes lands in the transcript exactly once.
            await self.push_frame(TTSSpeakFrame(text))
            try:
                await asyncio.wait_for(self._bot_stopped.wait(), 12.0)
            except TimeoutError:
                pass

    async def _app_speaks(self, url: str, text: str):
        """A session speaks through the app. Hold the voice lock and mute the mic
        for the line's estimated length: the app's voice is echo to this mic."""
        # Measured against three announcements on 23 Sep: 16 to 18 words each
        # took 8.1 to 8.4 s of real speech, and the transcriber finalises after
        # that again. The old 1.2 + 0.42w put the window's end inside the last
        # word every time, so the tail of the app's own voice reached the STT.
        secs = min(25.0, 1.5 + 0.5 * len(text.split()))
        async with self._voice:
            session.current().external_until["t"] = time.monotonic() + secs
            await _run("open", url)
            await asyncio.sleep(secs)

    async def _earcon(self, name: str):
        await emit(self, "earcon", name=name)
        if SOUNDS and os.getenv("TB_HOST") != "app" and not os.getenv("TB_HOSTED"):  # the app plays it
            wav = os.path.join(SOUNDS, f"{'needs-you' if name == 'needsYou' else name}.wav")
            asyncio.create_task(_run("afplay", wav))

    async def _targets(self) -> list[dict]:
        code, out = await _run(TBASE, "targets", "--json")
        data = _json_or_text(code, out).get("data")
        return data if isinstance(data, list) else []

    async def _waiting(self) -> list[dict]:
        code, out = await _run(TBASE, "status", "--json")
        data = _json_or_text(code, out).get("data") or {}
        return data.get("waiting", []) if isinstance(data, dict) else []

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
        """Grid order: unheard waiting rows first, then the rest of the live list;
        never the session already on stage."""
        current = (self.stage or {}).get("sessionId")
        waiting = [w for w in await self._waiting() if w["sessionId"] != current]
        live = {t["sessionId"]: t for t in await self._targets()}
        for w in sorted(waiting, key=lambda w: (w.get("heard", True), -w.get("eventId", 0))):
            if w["sessionId"] in live:
                return {**live[w["sessionId"]], **w}
        for t in live.values():
            if t["sessionId"] != current:
                return t
        return None

    async def _recent_briefs(self) -> list[dict]:
        out = []
        for w in (await self._waiting())[:5]:
            b = await self._brief(w["sessionId"])
            if b:
                out.append({"goal": b.get("goal"), "recap": b.get("recap"), "project": b.get("project")})
        return out


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
