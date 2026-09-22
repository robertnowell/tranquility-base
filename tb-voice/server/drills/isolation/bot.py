"""The probe agent: deliberately leaky, so the platform's behaviour is visible.

Pipecat Cloud documents that an instance runs one session at a time and that
"once a session concludes, the instance is returned to the pool and can
immediately serve another session". It does not say whether the Python process
is reset in between, and that is the whole question for us: the manager's own
memory lives in module-level names (`EXCHANGE` in manager.py, `EXTERNAL_UNTIL`
in mute.py), so if the process survives, one session's turns reach the next.

Everything below module level is per session. BOOT, PID and SESSIONS are not,
on purpose. Each session appends its own id and reports what the module can
see:

    {"drill":"isolation","boot":"b560ef5e…","pid":7,"count":5,"seen":[…],"up_s":129.8}

A boot id that answers more than once, with count climbing, means module state
survives a session boundary. Measured 22 Sep 2026: it does. Two processes
served seven sessions round-robin and one reached count 5, holding every id.

This agent is never the manager. `drill.py` deploys it under its own name,
runs the sessions and deletes it again (hf-2: drills must not share the
production manager agent).
"""

import asyncio
import json
import os
import time
import uuid

from loguru import logger

# Module state, on purpose: the thing under test.
BOOT = uuid.uuid4().hex[:12]
PID = os.getpid()
STARTED_AT = time.time()
SESSIONS: list[str] = []


async def bot(runner_args):
    """One session: append to the module list, report, close."""
    ws = runner_args.websocket
    session = getattr(runner_args, "session_id", None) or uuid.uuid4().hex[:8]
    SESSIONS.append(session)
    probe = {
        "drill": "isolation",
        "boot": BOOT,
        "pid": PID,
        "count": len(SESSIONS),
        "seen": SESSIONS[-20:],
        "up_s": round(time.time() - STARTED_AT, 1),
        "session": session,
    }
    logger.info(f"isolation probe {probe}")
    try:
        await ws.send_text(json.dumps(probe, separators=(",", ":")))
        await asyncio.sleep(1.0)  # let the client read before the socket closes
    finally:
        try:
            await ws.close()
        except Exception:  # noqa: BLE001 — the client may have gone first
            pass
