"""Hands-free invites the next agent in the grid's order, top to bottom.

Ruled 29 Sep, on a screenshot of the grid with project folders: "the order of
the agents speaking should be informed by the actual grid order top to bottom,
unread first." `tbase status` now carries each waiting row's `gridIndex`; the
manager sorts unheard first, then by that index, then newest first for rows the
panel does not show.
"""
import asyncio, sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import manager as M

TARGETS = [{"sessionId": s, "name": s} for s in ("top", "middle", "bottom", "offgrid")]


async def main() -> int:
    fails = []

    def check(what, ok):
        print(f"   {'ok  ' if ok else 'FAIL'}  {what}")
        if not ok:
            fails.append(what)

    mgr = M.Manager.__new__(M.Manager)
    mgr.stage = None
    waiting = []

    async def targets(self=None):
        return list(TARGETS)

    async def read_waiting(self=None):
        return [dict(w) for w in waiting]

    mgr._targets = targets
    mgr._waiting = read_waiting

    # Newest is lowest on the grid; the top row must still go first.
    waiting[:] = [
        {"sessionId": "bottom", "heard": False, "eventId": 300, "gridIndex": 2},
        {"sessionId": "top", "heard": False, "eventId": 100, "gridIndex": 0},
        {"sessionId": "middle", "heard": False, "eventId": 200, "gridIndex": 1},
    ]
    nxt = await mgr._next_session()
    check("the topmost unheard row goes first, not the newest", nxt and nxt["sessionId"] == "top")

    # Unread first: a heard row at the top waits behind an unheard one below.
    waiting[:] = [
        {"sessionId": "top", "heard": True, "eventId": 100, "gridIndex": 0},
        {"sessionId": "bottom", "heard": False, "eventId": 300, "gridIndex": 2},
    ]
    nxt = await mgr._next_session()
    check("unread first, even when a heard row sits above it", nxt and nxt["sessionId"] == "bottom")

    # A row the panel does not show comes after every row it does.
    waiting[:] = [
        {"sessionId": "offgrid", "heard": False, "eventId": 999},
        {"sessionId": "middle", "heard": False, "eventId": 1, "gridIndex": 1},
    ]
    nxt = await mgr._next_session()
    check("a row off the grid waits behind the grid", nxt and nxt["sessionId"] == "middle")

    # An older app that sends no gridIndex keeps the old order: newest first.
    waiting[:] = [
        {"sessionId": "top", "heard": False, "eventId": 100},
        {"sessionId": "bottom", "heard": False, "eventId": 300},
    ]
    nxt = await mgr._next_session()
    check("no gridIndex at all: newest first, as before", nxt and nxt["sessionId"] == "bottom")

    print("grid_order_drill:", "PASS" if not fails else f"FAIL {fails}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
