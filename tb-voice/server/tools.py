"""Tools the manager can call. Each one walks through a door the app already has:
`tbase` for reads and sends, the tranquilitybase:// scheme for speaking. See docs/design.md
section 6. Tools that make the app speak return run_llm=False so the manager stays quiet.
"""

import asyncio
import json
import os

from loguru import logger
from pipecat.adapters.schemas.function_schema import FunctionSchema
from pipecat.frames.frames import FunctionCallResultProperties

from events import line

TBASE = os.getenv("TBASE_BIN", "tbase")
SCHEME = os.getenv("TB_URL_SCHEME", "tranquilitybase")
SILENT = FunctionCallResultProperties(run_llm=False)


async def _run(*argv: str, timeout: float = 45.0) -> tuple[int, str]:
    logger.info("exec " + " ".join(argv))
    line("tool", argv=list(argv))
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


async def send_message(params):
    a = params.arguments
    code, out = await _run(TBASE, "send", a["session"], a["text"])
    meaning = {0: "confirmed", 2: "not dispatched", 3: "deferred", 4: "ambiguous target", 5: "failed"}
    await params.result_callback({"exit": code, "meaning": meaning.get(code, "unknown"), "text": out[-500:]})


async def start_agent(params):
    a = params.arguments
    argv = [TBASE, "new"]
    if a.get("directory"):
        argv.append(a["directory"])
    if a.get("harness") == "codex":
        argv.append("--codex")
    argv.append("--wait-live")
    code, out = await _run(*argv, timeout=60)
    reg = next((ln.split(":", 1)[1].strip() for ln in out.splitlines() if ln.startswith("registered:")), None)
    await params.result_callback({"exit": code, "session": reg, "text": out[-500:]})


async def invite_to_speak(params):
    sid = params.arguments["session"]
    code, out = await _run("open", f"{SCHEME}://hear?session={sid}")
    await params.result_callback({"exit": code, "status": "the session is speaking"}, properties=SILENT)


SCHEMAS = [
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
