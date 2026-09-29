"""A refused door is not an empty queue.

28 Sep, from the app's own reply on the wire:

    {'wire': 'result', 'ok': False,
     'error': {'code': 'too_large',
               'message': 'waiting result is over 16384 bytes and cannot be cut'}}

`tbase status --json` had grown to 29,160 bytes -- 200 waiting rows, 186 of
them for sessions long dead -- and the data channel refuses anything over
16,384. The reader found no list in that refusal and returned `[]`, so the
manager said "Nobody is waiting on you" while the grid in front of Robert
showed a column of green, and nothing anywhere said a door had been refused.

An empty list is a real answer: the queue is empty. It must not also be how a
failure arrives.
"""
import asyncio, json, sys

sys.path.insert(0, __file__.rsplit("/", 2)[0])

import manager as M


async def main() -> int:
    fails = []

    def check(what, ok):
        print(f"   {'ok  ' if ok else 'FAIL'}  {what}")
        if not ok:
            fails.append(what)

    rows = M._rows
    pick_list = lambda d: d if isinstance(d, list) else None
    pick_waiting = lambda d: d.get("waiting") if isinstance(d, dict) else None

    # The refusal that started it, in the shape `_run` hands back.
    refused = (1, "too_large: waiting result is over 16384 bytes and cannot be cut")
    raised = None
    try:
        rows(*refused, "the waiting list", pick_waiting)
    except M.DoorRefused as e:
        raised = e
    check("a refused door raises rather than returning nothing", raised is not None)
    check("and the reason survives, so the panel can show it",
          raised is not None and "16384" in str(raised))

    # The distinction the whole drill exists for.
    empty = rows(0, json.dumps({"waiting": [], "unannounced": 0}), "the waiting list", pick_waiting)
    check("an empty queue is still an empty queue", empty == [])

    full = rows(0, json.dumps({"waiting": [{"sessionId": "a"}], "unannounced": 1}),
                "the waiting list", pick_waiting)
    check("and rows come back as rows", full == [{"sessionId": "a"}])

    # The fleet door has the same shape and the same trap.
    check("a live fleet reads as a list",
          rows(0, json.dumps([{"sessionId": "a"}]), "the fleet", pick_list) == [{"sessionId": "a"}])
    raised = None
    try:
        rows(0, "not json at all", "the fleet", pick_list)
    except M.DoorRefused as e:
        raised = e
    check("an answer that is not rows raises even on exit 0", raised is not None)

    # A zero exit carrying the wrong shape is still a failure: JSON that parses
    # but is not the list we asked for cannot be silently read as no agents.
    raised = None
    try:
        rows(0, json.dumps({"unannounced": 5}), "the waiting list", pick_waiting)
    except M.DoorRefused as e:
        raised = e
    check("a reply missing the key we asked for raises", raised is not None)

    print("PASS" if not fails else f"FAIL: {len(fails)} case(s)")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
