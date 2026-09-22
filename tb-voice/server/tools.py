"""Tools the manager can call. Each one walks through a door the app already has:
`tbase` for reads and sends, the tranquilitybase:// scheme for speaking. See docs/design.md
section 6. Tools that make the app speak return run_llm=False so the manager stays quiet.
"""

import asyncio
import json
import os

from loguru import logger
from pipecat.adapters.schemas.function_schema import FunctionSchema
from pipecat.frames.frames import FunctionCallResultProperties, TTSSpeakFrame

import wire
from events import line
from wire import HOSTED

TBASE = os.getenv("TBASE_BIN", "tbase")
SCHEME = os.getenv("TB_URL_SCHEME", "tranquilitybase")
SILENT = FunctionCallResultProperties(run_llm=False)


async def _run(*argv: str, timeout: float = 45.0) -> tuple[int, str]:
    logger.info("exec " + " ".join(argv))
    line("tool", argv=list(argv))
    if HOSTED:
        # No tbase and no deep links where the bot runs: the app does it and replies.
        name = "tbase" if argv[0] == TBASE else argv[0]
        r = await wire.request("run", timeout=timeout, argv=[name, *argv[1:]])
        return int(r.get("code", 1)), str(r.get("out", ""))
    p = await asyncio.create_subprocess_exec(
        *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT
    )
    try:
        out, _ = await asyncio.wait_for(p.communicate(), timeout)
    except TimeoutError:
        p.kill()
        return 124, "timed out"
    return p.returncode or 0, out.decode(errors="replace")


def _json_or_text(code: int, out: str):
    try:
        return {"exit": code, "data": json.loads(out)}
    except Exception:
        return {"exit": code, "text": out[-2000:]}


async def list_agents(params):
    code, out = await _run(TBASE, "targets", "--json")
    await params.result_callback(_json_or_text(code, out))


async def whats_waiting(params):
    code, out = await _run(TBASE, "status", "--json")
    await params.result_callback(_json_or_text(code, out))


async def brief(params):
    code, out = await _run(TBASE, "brief", params.arguments["session"], "--json")
    await params.result_callback(_json_or_text(code, out))


SENT_LINE = os.getenv("TB_SENT_LINE", "I've sent your message. What's next?")


async def send_message(params):
    a = params.arguments
    sid = await _full_id(a["session"])
    code, out = await _run(TBASE, "send", sid, a["text"])
    meaning = {0: "sent", 2: "not dispatched", 3: "deferred", 4: "ambiguous target", 5: "failed"}
    line("tool", argv=["tbase", "send", sid[:8]], exit=code, meaning=meaning.get(code, "unknown"))
    if code == 0:
        # The sent cue and one fixed line; the model is not asked to narrate a send.
        line("earcon", name="dispatched")
        line("speaking", voice="manager", text=SENT_LINE)
        await params.llm.push_frame(TTSSpeakFrame(SENT_LINE))
        await params.result_callback({"exit": 0, "meaning": "sent"}, properties=SILENT)
    else:
        await params.result_callback({"exit": code, "meaning": meaning.get(code, "unknown"), "text": out[-300:]})


async def start_agent(params):
    a = params.arguments
    argv = [TBASE, "new"]
    if a.get("directory"):
        argv.append(a["directory"])
    if a.get("harness") == "codex":
        argv.append("--codex")
    code, out = await _run(*argv, timeout=60)
    reg = next((ln.split(":", 1)[1].strip() for ln in out.splitlines() if ln.startswith("registered:")), None)
    # The id is for tools, never for speech: the model gets "started" and the project.
    await params.result_callback({"exit": code, "started": reg is not None,
                                  "project": (a.get("directory") or "").rstrip("/").split("/")[-1] or "the default project",
                                  "session": reg})


async def _full_id(sid: str) -> str:
    """The manager keeps eight-character ids; the app's doors want the whole thing."""
    if len(sid) >= 32:
        return sid
    code, out = await _run(TBASE, "targets", "--json")
    data = _json_or_text(code, out).get("data") or []
    hits = [t["sessionId"] for t in data if isinstance(t, dict) and t.get("sessionId", "").startswith(sid)]
    return hits[0] if len(hits) == 1 else sid


async def invite_to_speak(params):
    sid = await _full_id(params.arguments["session"])
    code, out = await _run("open", f"{SCHEME}://hear?session={sid}")
    await params.result_callback({"exit": code, "status": "the session is speaking"}, properties=SILENT)


async def say_as_session(params):
    """The LLM's answer about the agent on stage, spoken in that agent's voice."""
    from urllib.parse import quote
    a = params.arguments
    text = " ".join(a["text"].split())[:600]
    sid = await _full_id(a["session"])
    code, out = await _run("open", f"{SCHEME}://say?session={sid}&text={quote(text)}")
    await params.result_callback({"exit": code, "status": "the session is speaking"}, properties=SILENT)


SCHEMAS = [
    FunctionSchema("say_as_session", "Speak a short answer (30 words max) in a session's own voice. Use for any answer about the agent on stage. Say nothing after.",
                   {"session": {"type": "string"}, "text": {"type": "string"}},
                   ["session", "text"], handler=say_as_session),
    FunctionSchema("list_agents", "List live coding-agent sessions with their state and ids.",
                   {}, [], handler=list_agents),
    FunctionSchema("whats_waiting", "Which sessions are waiting on the user, with their brief topic.",
                   {}, [], handler=whats_waiting),
    FunctionSchema("brief", "Read a session's latest brief: recap, proposal, goal, findings, solution, why.",
                   {"session": {"type": "string", "description": "session id or unique prefix"}},
                   ["session"], handler=brief),
    FunctionSchema("send_message", "Type a message into a session's terminal. Only when the target is unambiguous.",
                   {"session": {"type": "string"}, "text": {"type": "string"}},
                   ["session", "text"], handler=send_message),
    FunctionSchema("start_agent", "Start a new coding-agent session in a project directory.",
                   {"directory": {"type": "string"}, "harness": {"type": "string", "enum": ["claude", "codex"]}},
                   [], handler=start_agent),
    FunctionSchema("invite_to_speak", "Have a session speak its latest brief aloud in its own voice. Say nothing after.",
                   {"session": {"type": "string"}}, ["session"], handler=invite_to_speak),
]
