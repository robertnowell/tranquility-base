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
from pipecat.frames.frames import Frame, LLMContextFrame, TTSSpeakFrame
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from events import emit
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
    "invite_next": "Invite the next agent or session to speak; 'next agent'; 'who is up'",
    "rung_goal": "Asks what this project or piece of work is, or what the goal is",
    "rung_findings": "Asks what the agent found or what happened",
    "rung_solution": "Asks for the recommended next step, the solution, or what it proposes",
    "rung_why": "Asks why, for the rationale or reasoning",
    "custom": "Any other question or remark about the agent on stage or its work",
    "send_message": "Tells an agent to do something; a message or instruction to relay",
    "start_agent": "Asks to start, spin up, or open a new agent or session",
    "summarize_recent": "Asks what has been going on recently, across agents, or what we did",
    "teach": "Asks what the manager can do, what this is, or how it works",
    "none": "Addressed but nothing to do: an acknowledgement, a compliment, or filler",
}

RUNG_FOR = {"rung_goal": "goal", "rung_findings": "findings",
            "rung_solution": "solution", "rung_why": "why"}


class JevClient:
    def __init__(self, api_key: str):
        self._client = httpx.AsyncClient(
            headers={"Authorization": f"Bearer {api_key}"}, timeout=8.0)

    async def ask(self, state: dict, questions: dict) -> dict:
        r = await self._client.post(
            JEV_URL, json={"state": state, "model": "jev-latest", "questions": questions})
        r.raise_for_status()
        return r.json()["answers"]

    async def turn(self, utterance: str, recent: list[str], stage: dict | None):
        ctx = (f"The assistant is a voice manager named {NAME}. It listens to a developer "
               "thinking aloud while supervising a fleet of coding agents, and speaks only "
               "when addressed.")
        state = {"context": ctx, "recent_turns": recent[-3:], "utterance": utterance,
                 "agent_on_stage": (stage or {}).get("goal")}
        answers = await self.ask(state, {
            "addressed": {"type": "noul",
                "instructions": f"Is the speaker addressing the assistant {NAME} directly, with a request or a question meant for it?",
                "criteria": {"true": (f"Names {NAME}, or asks or instructs the assistant directly"
                                      + (", or asks about the agent on stage: its goal, findings, next step, reasons, or tells it to do something"
                                         if stage else "")),
                             "false": ("Thinking aloud, a rhetorical question, talking to another "
                                       f"person, reading text aloud, or the word {NAME.lower()} used for something else")}},
            "intent": {"type": "choice",
                "instructions": "If the assistant were addressed, which kind of request is this?",
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


def _chosen(choice: dict) -> str:
    # A Jev choice answer: {"choice": name, "confidence": c, "probabilities": {name: p}}.
    probs = choice.get("probabilities") or {}
    return choice.get("choice") or (max(probs.items(), key=lambda kv: kv[1])[0] if probs else "none")


class Manager(FrameProcessor):
    def __init__(self, jev: JevClient):
        super().__init__()
        self._jev = jev
        self._recent: list[str] = []
        self.stage: dict | None = None
        self.pending: dict | None = None  # a confirmation waiting for yes/no
        self.heard = 0
        self.addressed = 0

    async def hearing(self):
        """The user started speaking: the orb shows it before any verdict."""
        await emit(self, "hearing")

    # -- pipeline entry ------------------------------------------------------------

    async def process_frame(self, frame: Frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
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
        speak = p >= THRESHOLD
        logger.info(f"gate p={p:.2f} {intent} {ms}ms {'SPEAK' if speak else 'silent'} :: {text[:80]}")
        await emit(self, "addressed" if speak else "listening",
                   p=round(p, 2), intent=intent if speak else None, ms=ms, text=text[:120])
        if not speak:
            return
        self.addressed += 1
        handler = getattr(self, f"_do_{intent}", None)
        if handler:
            await handler(text, frame, direction)
        else:
            await self._llm(frame, direction, text, intent)

    # -- intents handled without the LLM ---------------------------------------------

    async def _do_none(self, text, frame, direction):
        await self._earcon("listening")

    async def _do_invite_next(self, text, frame, direction):
        nxt = await self._next_session()
        if not nxt:
            await self._say("Nobody is waiting, and I see no live sessions.")
            return
        self.stage = nxt
        await emit(self, "stage", session=nxt["sessionId"], goal=nxt.get("goal"),
                   project=nxt.get("project"))
        await self._earcon("returned")
        await _run("open", f"{SCHEME}://hear?session={nxt['sessionId']}")

    async def _do_rung_goal(self, t, f, d): await self._rung("goal")
    async def _do_rung_findings(self, t, f, d): await self._rung("findings")
    async def _do_rung_solution(self, t, f, d): await self._rung("solution")
    async def _do_rung_why(self, t, f, d): await self._rung("why")

    async def _rung(self, kind: str):
        if not self.stage:
            await self._say("Nobody is on stage yet. Say invite the next agent.")
            return
        brief = await self._brief(self.stage["sessionId"])
        rung = next((r for r in (brief or {}).get("rungs", []) if r["kind"] == kind), None)
        if not rung:
            have = [r["kind"] for r in (brief or {}).get("rungs", []) if r["kind"] != "message"]
            await self._say(f"That rung is empty for this turn. It has: {', '.join(have) or 'only the message'}.")
            return
        # The session speaks its own rung: a speak-only deep link into the app.
        await emit(self, "speaking", voice="agent", session=self.stage["sessionId"],
                   rung=kind, text=rung["spoken"][:160])
        await _run("open", f"{SCHEME}://rung?session={self.stage['sessionId']}&kind={kind}")

    async def _do_teach(self, text, frame, direction):
        await self._llm(frame, direction, text, "teach")

    # -- intents that need the LLM, with the stage handed over as a note ---------------

    async def _do_send_message(self, text, frame, direction):
        if self.stage:
            await self._llm(frame, direction, text, "send_message")
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
        else:
            await self._say(f"Not sent: {meaning}.")

    async def _llm(self, frame, direction, text, intent):
        note = {"intent": intent, "stage": self.stage and {
            "sessionId": self.stage["sessionId"], "goal": self.stage.get("goal"),
            "project": self.stage.get("project")}}
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
