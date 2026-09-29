"""One door to the Mac (hf-6): every effect the manager has goes by name.

Until this, anything the manager did on the Mac beyond four reads went over
`request:run`, which ran whatever `tbase` argv the bot sent. The app no longer
answers it. This plays a Mac that offers every tool and checks, in process,
that each of the manager's own doors goes to its named tool with an idem key
when it changes something, and none falls back to request:run:

  start       starting Claude Code or Codex, and enrolling it
  notes       starting the Notes agent and its quiet seed
  voice       the agent's own voice for an announcement
  open        the card an announcement opens, and mute
  reads       the fleet, the waiting list, a brief

Then a Mac from before this release, which offers only the reads, still gets
its effects over request:run (Prod can lag Dev by a release).

    TB_HOSTED=1 uv run python drills/one_door_drill.py
"""

import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import manager as M  # noqa: E402
import session  # noqa: E402
import wire  # noqa: E402
from manager import JevClient, Manager  # noqa: E402

failures: list[str] = []
SID = "abc12345-0000-4000-8000-000000000001"
NEW = "new00000-0000-4000-8000-000000000009"


def check(ok: bool, what: str):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def canned(tool: wire.Tool, args: dict) -> dict:
    data = {
        wire.Tool.AGENTS: [{"sessionId": SID, "name": "Planning"}],
        wire.Tool.WAITING: {"waiting": []},
        wire.Tool.BRIEF: {"sessionId": SID, "goal": "g"},
        wire.Tool.VOICE: {"cloud": "el-voice", "system": None},
        wire.Tool.START_AGENT: {"exit": 0, "out": f"starting\nregistered: {NEW}\n"},
        wire.Tool.ENROLL: {"exit": 0, "out": ""},
        wire.Tool.QUIET_SEND: {"exit": 0, "out": ""},
        wire.Tool.OPEN: {},
    }[tool]
    return {"ok": True, "data": data}


async def run(offered: set) -> tuple[list, list, dict]:
    session.bind()
    w = wire.bind()
    w.tools = offered
    w.hello_seen.set()
    calls, runs = [], []

    async def call(tool, args=None, deadline_ms=None, idem=None):
        if tool not in offered:
            return None
        calls.append((tool, args or {}, idem))
        return canned(tool, args or {})

    async def request(kind, timeout=45.0, **kw):
        runs.append(kw.get("argv"))
        argv = kw.get("argv") or []
        out = f"registered: {NEW}\n" if argv[1:2] == ["new"] else ""
        return {"code": 0, "out": out}

    wire.call, wire.request = call, request
    m = Manager(JevClient("drill-key-unused"))

    async def quiet(*a, **k):
        return None
    m._say = m._earcon = quiet
    m.broadcast_interruption = quiet
    out = {}
    out["targets"] = await m._targets()
    out["brief"] = await m._brief(SID)
    out["voice"] = await m._voice_for(SID)
    out["reg"] = await m._new_agent([M.TBASE, "new", "--codex"], "Codex")
    out["notes"] = await m._new_notes_agent(True)
    await m._do_mute("stop", None, None)
    await m._app_speaks(f"{M.SCHEME}://hear?session={SID}", "done", SID)
    return calls, runs, out


async def main():
    every = set(wire.Tool)
    calls, runs, out = await run(every)
    by = {}
    for tool, args, idem in calls:
        by.setdefault(tool, []).append((args, idem))
    check(not runs, f"no door fell back to request:run ({runs})")
    check(out["reg"] == NEW and by.get(wire.Tool.START_AGENT, [({}, None)])[0][0] == {"harness": "codex"},
          "start: a Codex start goes to start_agent and its registration is read back")
    check(any(a == {"agent": NEW} for a, _ in by.get(wire.Tool.ENROLL, [])), "start: the new agent is enrolled by name")
    check((out["notes"] or {}).get("sessionId") == NEW and wire.Tool.QUIET_SEND in by,
          "notes: the Notes agent starts and its seed goes by quiet_send")
    check(out["voice"] == "el-voice" and wire.Tool.VOICE in by, "voice: the agent's voice comes from the voice tool")
    urls = [a.get("url", "") for a, _ in by.get(wire.Tool.OPEN, [])]
    check(any(u.endswith("://mute") for u in urls) and any("://hear?" in u for u in urls),
          "open: mute and the announcement's card go to open")
    check(out["targets"] and out["brief"], "reads: the fleet and a brief still read")
    effects = [(t, idem) for t, _, idem in calls if t in wire.EFFECTS]
    check(effects and all(idem for _, idem in effects), "every effect carried an idem key")
    check(all(idem is None for t, _, idem in calls if t not in wire.EFFECTS), "no read carried one")

    old = {wire.Tool.AGENTS, wire.Tool.WAITING, wire.Tool.BRIEF, wire.Tool.TRANSCRIPT, wire.Tool.SEND}
    calls, runs, out = await run(old)
    subs = [r[1] if len(r) > 1 and r[0] == "tbase" else r[0] for r in runs]
    check({"voice", "new", "enroll", "send", "open"} <= set(subs),
          f"an older Mac still gets its effects over request:run ({subs})")
    check(out["reg"] == NEW, "an older Mac can still start an agent")

    print(f"\n{'FAIL' if failures else 'PASS'}: {len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    asyncio.run(main())
