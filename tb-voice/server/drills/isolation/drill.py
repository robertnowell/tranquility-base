"""Its own agent, up and down again: deploy, run N sessions, assert, delete.

    uv run python drills/isolation/drill.py            # deploy, 4 sessions, delete
    uv run python drills/isolation/drill.py --keep     # leave it up to poke at
    uv run python drills/isolation/drill.py --agent X  # against an existing agent

Why a drill gets its own agent (hf-2): test sessions started against
`tranquility-manager` land in the same warm process as the real ones, so their
turns end up in the user's context. That is how the leak was found in the first
place. A drill deploys its own agent, uses it, and deletes it.

What it asserts:

  1. Every session got a probe back at all (the deploy works, the socket works).
  2. The platform's behaviour is REPORTED, not asserted: whether one process
     served more than one session. This is the precondition for the manager's
     own isolation test, and it is not ours to fix. Measured 22 Sep 2026: one
     process served five of seven sessions.
  3. No session saw another session's id in a per-session structure — which for
     this agent is vacuous by construction, and is the line the manager's own
     drill replaces with "session 2's first classifier call carries none of
     session 1's turns".

Exit code 0 when the probes came back, 1 when the drill could not measure.
"""

import argparse
import asyncio
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import httpx
import websockets

HERE = Path(__file__).resolve().parent
PCC = os.getenv("PIPECAT_BIN", str(Path.home() / ".local/bin/pipecat"))
START = "https://api.pipecat.daily.co/v1/public/{agent}/start"


def key() -> str:
    """The public start key: the dev shim's, the same one the app uses."""
    if os.getenv("PCC_KEY"):
        return os.environ["PCC_KEY"]
    config = Path.home() / ".claude/hq.json"
    return json.loads(config.read_text())["manager"]["hosted"]["key"]


def cli(*args: str) -> int:
    print(f"→ pipecat cloud {' '.join(args)}", flush=True)
    return subprocess.run([PCC, "cloud", *args], cwd=HERE).returncode


async def session(agent: str, n: int) -> dict:
    """One session: buy it, connect, read the probe, hang up."""
    t0 = time.monotonic()
    async with httpx.AsyncClient(timeout=60) as http:
        r = await http.post(
            START.format(agent=agent),
            headers={"Authorization": f"Bearer {key()}", "Content-Type": "application/json"},
            json={"transport": "websocket"},
        )
        r.raise_for_status()
        bought = r.json()
    headers = {"Authorization": f"Bearer {bought['token']}"} if bought.get("token") else {}
    probe = None
    async with websockets.connect(bought["wsUrl"], additional_headers=headers) as ws:
        try:
            while probe is None:
                msg = await asyncio.wait_for(ws.recv(), timeout=25)
                if isinstance(msg, str):
                    probe = json.loads(msg)
        except (asyncio.TimeoutError, websockets.exceptions.ConnectionClosed) as e:
            print(f"  session {n}: no probe ({type(e).__name__})")
    if probe:
        probe["start_ms"] = int((time.monotonic() - t0) * 1000)
    return probe or {}


async def run(agent: str, count: int, gap: float) -> list[dict]:
    probes = []
    for n in range(1, count + 1):
        p = await session(agent, n)
        if p:
            print(f"  session {n}  boot {p['boot']}  count {p['count']}  "
                  f"up {p['up_s']:>6} s  start {p['start_ms']:>4} ms")
        probes.append(p)
        if n < count:
            await asyncio.sleep(gap)
    return probes


def verdict(probes: list[dict]) -> int:
    got = [p for p in probes if p]
    print()
    if len(got) != len(probes):
        print(f"✗ {len(probes) - len(got)} of {len(probes)} sessions returned no probe")
        return 1
    boots: dict[str, list[dict]] = {}
    for p in got:
        boots.setdefault(p["boot"], []).append(p)
    reused = {b: ps for b, ps in boots.items() if len(ps) > 1}
    print(f"✓ {len(got)} sessions, {len(boots)} process(es)")
    for b, ps in boots.items():
        print(f"    {b}: {len(ps)} session(s), module count reached {max(p['count'] for p in ps)}")
    if reused:
        print("\n! module state SURVIVES a session boundary on this platform:")
        for b, ps in reused.items():
            print(f"    {b} served {len(ps)} sessions in one process and remembered "
                  f"{max(p['count'] for p in ps)}")
        print("  So nothing in the manager may live at module scope (hf-1).")
    else:
        print("\n  No process served twice in this run. Raise --count, or check that "
              "min-agents keeps one instance warm, before concluding anything.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--agent", default="isolation-drill")
    ap.add_argument("--count", type=int, default=4)
    ap.add_argument("--gap", type=float, default=2.0)
    ap.add_argument("--keep", action="store_true", help="do not delete the agent afterwards")
    ap.add_argument("--no-deploy", action="store_true", help="use an agent that is already up")
    args = ap.parse_args()

    # Both names. `tranquility-manager` was production until the WebSocket
    # transport went on 25 Sep and `tranquility-manager-rtc` took over; a
    # guard that still named only the retired one would have let a drill
    # deploy over the live manager, which is the exact accident it exists to
    # prevent. The old name stays because the guard costs nothing and a
    # resurrected agent would be production again.
    if args.agent in ("tranquility-manager-rtc", "tranquility-manager"):
        print(f"✗ refusing: {args.agent} is a production manager (hf-2). Use a drill agent.")
        return 1

    deployed = False
    if not args.no_deploy:
        if cli("deploy", args.agent, "--build-dir", ".", "--dockerfile", "Dockerfile",
               "--min-agents", "1", "--max-agents", "1", "--yes") != 0:
            print("✗ deploy failed")
            return 1
        deployed = True
        time.sleep(15)  # the first instance needs a moment after ready

    try:
        probes = asyncio.run(run(args.agent, args.count, args.gap))
        return verdict(probes)
    finally:
        if deployed and not args.keep:
            cli("agent", "delete", args.agent, "--force")


if __name__ == "__main__":
    sys.exit(main())
