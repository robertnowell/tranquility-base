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
    BotStoppedSpeakingFrame,
    Frame,
    LLMContextFrame,
    StartFrame,
    TTSSpeakFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from calls import record
from events import emit
from compose import READBACK_SECS, OpenMessage, classify, continues, filler_only
from mute import EXTERNAL_UNTIL
from spoken import spoken
from tools import _json_or_text, _run

JEV_URL = "https://api.typesafe.ai/v1/systemone"
NAME = os.getenv("TB_MANAGER_NAME", "Tranquility")
THRESHOLD = float(os.getenv("TB_ADDRESSED_THRESHOLD", "0.5"))
HOLD_SECS = float(os.getenv("TB_HOLD_SECS", "1.2"))
HOLD_NAMED_SECS = float(os.getenv("TB_HOLD_NAMED_SECS", "2.5"))
SCHEME = os.getenv("TB_URL_SCHEME", "tranquilitybase")
SOUNDS = os.getenv("TB_SOUNDS", "")
TBASE = os.getenv("TBASE_BIN", "tbase")
if not os.path.exists(TBASE) and TBASE != "tbase":
    logger.warning(f"TBASE_BIN {TBASE} does not exist; reads will fail closed")

INTENTS = {
    "invite_next": "Invite the next agent or session to speak; 'next agent'; 'who is up'; 'what's next' when no agent is on stage",
    "rung_goal": "Asks what this project or piece of work is, or what the goal is",
    "rung_findings": "Asks what the agent found or what happened",
    "rung_solution": "Asks for the recommended next step, the solution, or what it proposes",
    "rung_why": "Asks why, for the rationale or reasoning",
    "custom": "Any other question about the agent on stage or its work: files, code, status, details, opinions",
    "send_message": "Tells an agent to do something; a message or instruction to relay",
    "start_agent": "Asks to start, spin up, or open a new agent or session",
    "take_note": "Asks to take a note, dictate a note, or put something on the clipboard",
    "summarize_recent": "Asks what has been going on recently across ALL agents, or what we did today or yesterday; not about one session",
    "teach": "Asks what the manager can do, what this is, or how it works",
    "speak": "Tells the manager to say something, speak, respond, answer, or prove it is listening",
    "mute": "Tells whoever is talking to stop, pause, be quiet, mute, hold on, or that's enough",
    "none": "Addressed but nothing to do: an acknowledgement, a compliment, or filler",
}

# How the transcriber has actually spelled the name, from bot.log. A word that
# starts like one of these, at the start of a turn, is the name; the gate does
# not get to disagree with the person saying it.
NAME_SOUNDS = ("tranq", "trank", "drink", "tranc", "trinq", "tranguil", "tranqu")


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
COMMANDS = {"invite_next", "send_message", "start_agent", "take_note", "rung_goal", "rung_findings",
            "rung_solution", "rung_why", "summarize_recent", "mute"}

# Intents that take seconds (a tool run, a model call) before anything is heard.
SLOW_INTENTS = {"send_message", "summarize_recent", "custom", "teach", "speak"}

# With a session on stage, a confident question about its work is for the manager.
STAGE_QUESTIONS = {"rung_goal", "rung_findings", "rung_solution", "rung_why", "custom", "send_message"}

RUNG_FOR = {"rung_goal": "goal", "rung_findings": "findings",
            "rung_solution": "solution", "rung_why": "why"}


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
                {"who": e["who"], "status": e["status"], "text": e["text"]} for e in EXCHANGE[-8:]
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
                "criteria": INTENTS},
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


# The conversation before the text being judged: who said it, what, and whether it
# was already handled. Every earlier turn is context and only context; a request
# that was acted on is marked so it is never replayed.
EXCHANGE: list[dict] = []


def note(who: str, text: str, status: str = "said"):
    """What was said, by whom, for a person to read later and for the models to
    see as context. Seeded from the transcript on start so a restart forgets nothing."""
    EXCHANGE.append({"who": who, "text": text.strip(), "status": status})
    del EXCHANGE[:-12]
    if os.getenv("TB_HOSTED"):
        return  # no transcript on disk where the bot is hosted; the app keeps its own
    with open(TRANSCRIPT, "a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}  {who} [{status}]: {text.strip()}\n")


def seed_exchange():
    try:
        with open(TRANSCRIPT) as f:
            for raw in f.readlines()[-12:]:
                parts = raw.rstrip("\n").split("  ", 1)
                if len(parts) != 2 or ": " not in parts[1]:
                    continue
                head, text = parts[1].split(": ", 1)
                who, _, status = head.partition(" [")
                EXCHANGE.append({"who": who, "text": text, "status": status.rstrip("]") or "said"})
    except FileNotFoundError:
        pass


def exchange_lines(n: int = 8) -> list[str]:
    return [f"{e['who']} ({e['status']}): {e['text']}" for e in EXCHANGE[-n:]]


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
            headers={"Authorization": f"Bearer {os.environ.get('GC_API_KEY', '')}"}, timeout=20.0)
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

    async def answer(self, question: str, brief: dict, recent: list[str]) -> str:
        facts = {k: brief.get(k) for k in ("goal", "recap", "proposal", "findings", "solution", "why", "lastAssistantMessage")}
        tail = self.transcript_tail(brief.get("transcriptPath"))
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

    async def compose_message(self, request: str, exchange: list[str]) -> str:
        """The message to type into the agent's terminal, from the developer's own
        words: the request itself when it carries the instruction ('tell it to run
        the tests'), or the dictated turns before it ('send that message')."""
        msgs = [
            {"role": "system", "content": (
                "You turn a developer's spoken words into the exact message to type into a coding "
                "agent's terminal. Use their words; drop filler, false starts and asides about the "
                "assistant itself. If the request carries the instruction ('tell it to run the tests'), "
                "the message is that instruction addressed to the agent ('Run the tests'). If the "
                "request refers to a message they just dictated ('send that message', 'send it'), the "
                "message is the dictated turns marked 'you (silent)' that come after the last spoken "
                "or acted line, joined into clean prose. Output ONLY the message text, no preamble.")},
            {"role": "user", "content": "Exchange (oldest first):\n" + "\n".join(exchange) + f"\n\nRequest: {request}"},
        ]
        body = {"model": self.model, "messages": msgs, "max_tokens": 600, "temperature": 0.2}
        t0 = time.monotonic()
        r = await self._client.post("/chat/completions", json=body)
        r.raise_for_status()
        record("brain", body, r.json(), ms=int((time.monotonic() - t0) * 1000))
        return (r.json()["choices"][0]["message"].get("content") or "").strip()


class Manager(FrameProcessor):
    def __init__(self, jev: JevClient):
        super().__init__()
        self._jev = jev
        self._brain = Brain()
        seed_exchange()
        self._recent: list[str] = []
        self.stage: dict | None = None
        self.pending: dict | None = None  # a confirmation waiting for yes/no
        self.open: OpenMessage | None = None  # dictation with a destination (compose.py)
        self._wire_task = None  # hosted: drains wire.outbox into transport messages
        self._readback_task: asyncio.Task | None = None
        self.heard = 0
        self.addressed = 0
        self._bot_stopped = asyncio.Event()
        self._voice = asyncio.Lock()        # one voice at a time, manager or agent
        self._held: str | None = None       # a turn that ended mid-sentence, waiting for its rest
        self._user_speaking = False         # between on_user_turn_started and the next context frame
        self._held_task: asyncio.Task | None = None

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

    async def cleanup(self):
        if self._wire_task:
            await self.cancel_task(self._wire_task)
            self._wire_task = None
        await super().cleanup()

    async def hearing(self):
        """The user started speaking: the orb shows it before any verdict."""
        self._user_speaking = True
        await emit(self, "hearing")

    # -- pipeline entry ------------------------------------------------------------

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, StartFrame):
            if os.getenv("TB_HOSTED") and self._wire_task is None:
                self._wire_task = self.create_task(self._drain_wire())
            # The pipeline is running and the mic is open: now it is listening.
            await emit(None, "ready")
        if isinstance(frame, BotStoppedSpeakingFrame):
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
            # Dictation: every word is the message. No hold, no gate, no Jev intent.
            self._handler = asyncio.create_task(self._compose_turn(text, frame, direction))
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
        if not text.rstrip().endswith((".", "?", "!")):
            self._held = text
            wait = HOLD_NAMED_SECS if names_the_manager(text) else HOLD_SECS
            self._held_task = asyncio.create_task(self._release_held(frame, direction, wait))
            return
        self.heard += 1
        # The handler runs detached: an interruption cancels the frame task it
        # started from, and an invite that dies between "Inviting…" and the hear
        # verb leaves nobody speaking (16:49:39).
        self._handler = asyncio.create_task(self._handle_turn(text, frame, direction))
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
            self._handler = asyncio.create_task(self._handle_turn(text, frame, direction))
            self._recent.append(text)

    async def _handle_turn(self, text, frame, direction):
        try:
            if self.pending:
                await self._resolve_pending(text, frame, direction)
            else:
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
        intent = _chosen(intent_answer)
        low = text.lower()
        if "send" in low and any(w in low for w in ("message", "to this agent", "to the agent", "to it")):
            intent = "send_message"  # the words say so; Jev's tie-break does not
        if not self.stage and intent in RUNG_FOR:
            # "What's next?" with nobody on stage is the ⌃⌥ question: the next
            # agent's update, not a lecture about the stage being empty.
            intent = "invite_next"
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
        logger.info(f"gate p={p:.2f} {intent} {ms}ms {'SPEAK' if speak else 'silent'} :: {text[:80]}")
        note("you", text, "acted" if speak else "silent")
        await emit(self, "addressed" if speak else "listening",
                   p=round(p, 2), intent=intent if speak else None, ms=ms, text=text[:120])
        if not speak:
            return
        self.addressed += 1
        # The activation cue covers latency you would otherwise fill by repeating
        # yourself. An invite or a rung speaks within a second; a cue there lands
        # on top of the voice. Only the slow intents get one.
        if intent in SLOW_INTENTS:
            await self._earcon("listening")
        handler = getattr(self, f"_do_{intent}", None)
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
        await emit(self, "speaking", voice="agent", session=nxt["sessionId"], text=spoken[:200])
        note(nxt.get("name") or nxt.get("goal") or nxt["sessionId"][:8], spoken or "(no brief stored)", "spoken")
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
                   rung=kind, text=rung["spoken"][:160])
        note(self.stage.get("name") or self.stage.get("goal") or self.stage["sessionId"][:8], rung["spoken"], "spoken")
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
            await emit(self, "addressed", p=1.0, intent="send_message", ms=0, text=text[:120])
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
            answer = await self._brain.answer(question, brief, self._recent)
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
        note(self.stage.get("name") or self.stage.get("goal") or sid[:8], answer, "spoken")
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
        if any(w in low for w in ("control", "what can you", "how do i", "commands", "what do you do")):
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
            try:
                message = await self._brain.compose_message(text, exchange_lines(12))
            except Exception as e:
                logger.error(f"compose failed: {e}")
                await emit(self, "error", reason=f"compose: {str(e)[:120]}")
                await self._say("I couldn't put that message together.")
                return
            if not message:
                await self._open({"kind": "agent", "sessionId": self.stage["sessionId"],
                                  "name": self.stage.get("name") or self.stage.get("project") or "the agent"})
                return
            await emit(self, "speaking", voice="manager", text=f"message: {message[:160]}")
            note("Tranquility", f"(typing into {self.stage.get('goal') or 'the stage'}) {message}", "acted")
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
            seed = await self._brain.compose_message(text, exchange_lines(6))
        except Exception:
            seed = ""
        await self._open({"kind": "agent", "sessionId": c["sessionId"],
                          "name": c.get("name") or c.get("project") or "the agent"}, seed=seed)

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
        with open(NOTES_STATE, "w") as f:
            f.write(reg + "\n")
        await _run(TBASE, "enroll", reg, timeout=10)
        await self._send(reg, NOTES_SEED, quiet=True)
        return {"kind": "agent", "sessionId": reg, "name": "Notes"}

    # -- the open message ------------------------------------------------------------

    async def _open(self, destination: dict, line: str | None = None, seed: str = ""):
        self.pending = None
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
        if verdict == "content" and continues(m.last):
            pass  # a continuation is content, whatever it sounds like alone
        elif verdict == "content" and m.asked:
            # After the read-back, a short reply is an answer to "send?".
            ans = _chosen(await self._jev.confirm(text, f"Send to {m.name}?")) if len(text.split()) <= 6 else "other"
            verdict = {"yes": "send", "no": "hold"}.get(ans, "content")
            if verdict != "content":
                remainder = ""  # the answer is not part of the message
        if verdict == "content" and not continues(m.last) and len(text.split()) <= 12:
            # Short, complete, and not a known phrase: let Jev say whether it is about the message.
            k = await self._jev.compose(text, m.text[-600:], m.name)
            if float(k.get("confidence", 0)) >= 0.85 and _chosen(k) in ("send", "cancel", "retarget", "hold"):
                verdict, remainder = _chosen(k), ""
        await emit(self, "listening" if verdict == "content" else "addressed",
                   p=1.0, intent=f"compose:{verdict}", ms=0, text=text[:120])
        if verdict == "content":
            if filler_only(text):
                return  # a breath the segmenter cut out; not part of the message
            if m.append(text):
                note("you", text, "dictated")
                await self._show_draft()
            self._arm_readback()
            return
        if verdict == "hold":
            note("you", text, "acted")
            m.asked = True  # no second read-back until more is said
            return
        if verdict == "cancel":
            note("you", text, "acted")
            await self._close()
            await self._say("Dropped.")
            return
        if verdict == "retarget":
            note("you", text, "acted")
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
            note("you", remainder, "dictated")
        note("you", text, "acted")
        await self._deliver()

    async def _deliver(self):
        m = self.open
        if not m or not m.text.strip():
            await self._say("There's nothing to send yet.")
            return
        text, dest = m.text.strip(), m.destination
        await self._close()
        note("Tranquility", f"(typing into {dest.get('name')}) {text}", "acted")
        await self._send(dest["sessionId"], text)

    async def _close(self):
        if self._readback_task:
            self._readback_task.cancel()
            self._readback_task = None
        self.open = None
        await emit(self, "quiet")

    async def _ask_confirm(self):
        sid, _ = self.pending["ranked"][self.pending["index"]]
        c = self.pending["live"][sid]
        q = f"To {c.get('name') or c.get('goal') or c['project']}?"
        self.pending["question"] = q
        await self._say(q)

    async def _resolve_pending(self, text, frame, direction):
        answer = _chosen(await self._jev.confirm(text, self.pending["question"]))
        await emit(self, "addressed", p=1.0, intent=f"confirm:{answer}", ms=0, text=text[:120])
        if answer == "yes":
            sid, _ = self.pending["ranked"][self.pending["index"]]
            self.stage = self.pending["live"][sid]
            msg = self.pending["text"]
            self.pending = None
            await self._send(sid, msg)
        elif answer == "no":
            self.pending["index"] += 1
            if self.pending["index"] >= len(self.pending["ranked"]):
                self.pending = None
                await self._say("Out of candidates. Name the project and I will send it.")
            else:
                await self._ask_confirm()
        else:
            self.pending = None
            await self._turn(text, frame, direction)

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
        note = {"intent": intent, "stage": self.stage and {
            "sessionId": self.stage["sessionId"], "goal": self.stage.get("goal"),
            "project": self.stage.get("project")}}
        if self.stage and intent == "custom":
            brief = brief or await self._brief(self.stage["sessionId"])
            if brief:
                note["brief"] = {k: brief.get(k) for k in ("goal", "recap", "proposal", "findings", "solution", "why", "lastAssistantMessage")}
                note["instruction"] = "Answer the question from this brief in the session's own voice via say_as_session, 30 words max."
        if intent == "send_message" and self.stage:
            note["instruction"] = ("Call send_message with the stage sessionId now; do not ask "
                                   "which session. Then confirm in one clause.")
        if intent == "summarize_recent":
            note["recent"] = await self._recent_briefs()
        frame.context.add_message({"role": "developer", "content": "manager note: " + json.dumps(note)})
        await emit(self, "speaking", intent=intent, stage=(self.stage or {}).get("goal"))
        await self.push_frame(frame, direction)

    # -- doors ----------------------------------------------------------------------

    async def _say(self, text: str, voice: str = "manager", session: str | None = None):
        """The manager's voice. Holds the voice lock until its own speech stops,
        so nothing else can start talking over it."""
        async with self._voice:
            await emit(self, "speaking", voice=voice, session=session, text=text[:160])
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
        secs = min(20.0, 1.2 + 0.42 * len(text.split()))
        async with self._voice:
            EXTERNAL_UNTIL["t"] = time.monotonic() + secs
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
