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
from pipecat.frames.frames import BotStoppedSpeakingFrame, Frame, LLMContextFrame, TTSSpeakFrame
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from calls import record
from events import emit
from spoken import spoken
from tools import _json_or_text, _run

JEV_URL = "https://api.typesafe.ai/v1/systemone"
NAME = os.getenv("TB_MANAGER_NAME", "Tranquility")
THRESHOLD = float(os.getenv("TB_ADDRESSED_THRESHOLD", "0.5"))
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
COMMANDS = {"invite_next", "send_message", "start_agent", "rung_goal", "rung_findings",
            "rung_solution", "rung_why", "summarize_recent", "mute"}

# Intents that take seconds (a tool run, a model call) before anything is heard.
SLOW_INTENTS = {"send_message", "start_agent", "summarize_recent", "custom", "teach", "speak"}

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
        crit = {c["sessionId"]: f"{c.get('goal') or c.get('topic') or c['project']}" for c in candidates}
        answers = await self.ask(
            {"utterance": utterance, "sessions": crit},
            {"target": {"type": "choice",
                        "instructions": "Which session is this message meant for, judged by its goal?",
                        "criteria": crit}})
        return answers["target"]

    async def confirm(self, utterance: str, question: str) -> dict:
        answers = await self.ask(
            {"question_asked": question, "reply": utterance},
            {"answer": {"type": "choice", "instructions": "How did the speaker answer?",
                        "criteria": {"yes": "Agrees, confirms, go ahead",
                                     "no": "Declines, 'not that one', a different target",
                                     "other": "Unrelated, or talking to someone else"}}})
        return answers["answer"]


TRANSCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "transcript.md")


# The conversation before the text being judged: who said it, what, and whether it
# was already handled. Every earlier turn is context and only context; a request
# that was acted on is marked so it is never replayed.
EXCHANGE: list[dict] = []


def note(who: str, text: str, status: str = "said"):
    """What was said, by whom, for a person to read later and for the models to
    see as context. Seeded from the transcript on start so a restart forgets nothing."""
    EXCHANGE.append({"who": who, "text": text.strip(), "status": status})
    del EXCHANGE[:-12]
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
                "'the branch', 'the PR', 'PR five forty-seven'.")},
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
        self.heard = 0
        self.addressed = 0
        self._bot_stopped = asyncio.Event()

    async def _say_and_wait(self, text: str, timeout: float = 8.0):
        """Speak in the manager's voice and return when the voice has stopped, so
        what follows (an agent's voice) does not land on top of it."""
        self._bot_stopped.clear()
        await self._say(text)
        try:
            await asyncio.wait_for(self._bot_stopped.wait(), timeout)
        except TimeoutError:
            pass

    async def hearing(self):
        """The user started speaking: the orb shows it before any verdict."""
        await emit(self, "hearing")

    # -- pipeline entry ------------------------------------------------------------

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, BotStoppedSpeakingFrame):
            self._bot_stopped.set()
        if not isinstance(frame, LLMContextFrame):
            await self.push_frame(frame, direction)
            return
        if frame.speculation:
            return
        text = _last_user_text(frame)
        if not text:
            await self.push_frame(frame, direction)
            return
        self.heard += 1
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
        self._recent.append(text)

    async def _turn(self, text, frame, direction):
        t0 = time.monotonic()
        p, intent_answer = await self._jev.turn(text, self._recent, self.stage)
        ms = int((time.monotonic() - t0) * 1000)
        intent = _chosen(intent_answer)
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
                   project=nxt.get("project"))
        who = nxt.get("goal") or nxt.get("project") or "the next agent"
        await self._say_and_wait(f"Inviting {who} to speak.")
        await asyncio.sleep(0.2)  # a breath between the manager's voice and the agent's
        brief = await self._brief(nxt["sessionId"])
        spoken = " ".join(x for x in ((brief or {}).get("recap"), (brief or {}).get("proposal")) if x)
        await emit(self, "speaking", voice="agent", session=nxt["sessionId"], text=spoken[:200])
        note(nxt.get("goal") or nxt.get("project") or nxt["sessionId"][:8], spoken or "(no brief stored)", "spoken")
        await _run("open", f"{SCHEME}://hear?session={nxt['sessionId']}")

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
        note(self.stage.get("goal") or self.stage["sessionId"][:8], rung["spoken"], "spoken")
        await _run("open", f"{SCHEME}://rung?session={self.stage['sessionId']}&kind={kind}")

    async def _do_custom(self, text, frame, direction):
        if not self.stage:
            await self._llm(frame, direction, text, "custom")
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
        note(self.stage.get("goal") or sid[:8], answer, "spoken")
        await _run("open", f"{SCHEME}://say?session={sid}&text={quote(answer)}")

    CAPABILITIES = ("Say what's next to hear the next agent. Ask for the goal, findings, next step "
                    "or why. Say tell it to, then your message. Say stop to mute. Say start an agent.")

    async def _do_teach(self, text, frame, direction):
        """Teach without a tool-choosing model: showing means reading the fleet
        aloud, controls are a fixed line, and 'what is this' is one plain answer."""
        low = text.lower()
        if any(w in low for w in ("show", "see", "session", "agent", "who is", "who's", "what's going on", "waiting")):
            live = await self._targets()
            waiting = await self._waiting()
            if not live and not waiting:
                await self._say("I can't see any live sessions right now.")
                return
            first = (waiting or live)[0]
            who = first.get("goal") or first.get("topic") or first.get("project") or "one"
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
        if self.stage:
            await self._say(f"Listening. On stage: {self.stage.get('goal') or self.stage.get('project')}. Ask for the next step, or say next agent.")
            return
        waiting = await self._waiting()
        if waiting:
            first = waiting[0]
            await self._say(f"Listening. {len(waiting)} waiting on you; first is {first.get('goal') or first.get('project')}. Say invite the next agent.")
        else:
            await self._say("Listening. Nobody is waiting on you. Say invite the next agent, or name a project.")

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
                await self._say("I don't have a message to send. Say it, then say send.")
                return
            await emit(self, "speaking", voice="manager", text=f"message: {message[:160]}")
            note("Tranquility", f"(typing into {self.stage.get('goal') or 'the stage'}) {message}", "acted")
            await self._send(self.stage["sessionId"], message)
            return
        live = await self._targets()
        if not live:
            await self._say("I see no live sessions to send to.")
            return
        choice = await self._jev.target(text, live)
        ranked = sorted(choice.get("probabilities", {}).items(), key=lambda kv: -kv[1]) or [(_chosen(choice), 1.0)]
        self.pending = {"kind": "target", "text": text, "ranked": ranked, "live": {c["sessionId"]: c for c in live}, "index": 0}
        await self._ask_confirm()

    async def _ask_confirm(self):
        sid, _ = self.pending["ranked"][self.pending["index"]]
        c = self.pending["live"][sid]
        q = f"To the one working on {c.get('goal') or c.get('topic') or c['project']}?"
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

    async def _send(self, session_id: str, text: str):
        code, out = await _run(TBASE, "send", session_id, text)
        meaning = {0: "sent", 2: "not dispatched", 3: "deferred", 4: "ambiguous", 5: "failed"}.get(code, "unknown")
        await emit(self, "tool", argv=["tbase", "send", session_id[:8]], exit=code, meaning=meaning)
        if code == 0:
            await self._earcon("dispatched")
            await self._say(os.getenv("TB_SENT_LINE", "Sent. What's next?"))
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
        await emit(self, "speaking", voice=voice, session=session, text=text[:160])
        # The synthesizer notes the line when it speaks it (tts.py), so every
        # path the manager's voice takes lands in the transcript exactly once.
        await self.push_frame(TTSSpeakFrame(text))

    async def _earcon(self, name: str):
        await emit(self, "earcon", name=name)
        if SOUNDS and os.getenv("TB_HOST") != "app":  # hosted by the app, the app plays it
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
