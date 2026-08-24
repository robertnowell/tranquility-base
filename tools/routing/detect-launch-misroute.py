#!/usr/bin/env python3
"""Detect replies that were spoken into a greeting card but delivered elsewhere.

The fingerprint of the 24 Aug misroute, stated as a machine check:

  1. a launch is adopted        -> `launch: replies now go to <X>`   at time T
  2. a capture was ALREADY OPEN at T (mic opened at or before adoption)
  3. that capture's dispatch    -> `confirmAndSend -> dispatched(... sessionId: "<Z>" ...)`
  4. Z != X, and no `launch: reply waited` line sits between the mic open and the
     dispatch (that line is printed on every correctly-routed launch reply)

Run over ~/Library/Application Support/VoiceDispatch/app.log. Exit 1 if any hit.
"""
import re, sys, os
from datetime import datetime, timedelta

LOG = os.path.expanduser("~/Library/Application Support/VoiceDispatch/app.log")
TS = re.compile(r"^(\S+Z) \[(\d+)\]\s+(.*)$")
ADOPT = re.compile(r"launch: replies now go to (\w+)")
CAP = re.compile(r"capture: ([\d.]+)s open")
DISP = re.compile(r'confirmAndSend -> dispatched\(.*sessionId: "([0-9a-f-]+)"', re.S)
WAITED = re.compile(r"launch: reply waited")

def parse(path):
    for raw in open(path, errors="replace"):
        m = TS.match(raw.rstrip("\n"))
        if m:
            yield datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ"), m.group(2), m.group(3)

events = list(parse(LOG))
adoptions = [(t, pid, ADOPT.search(msg).group(1)) for t, pid, msg in events if ADOPT.search(msg)]

hits = []
for T, apid, X in adoptions:
    # the first capture that CLOSED after T, in the same process
    for i, (C, pid, msg) in enumerate(events):
        if pid != apid or C < T:
            continue
        m = CAP.search(msg)
        if not m:
            continue
        S = C - timedelta(seconds=float(m.group(1)))   # mic opened here
        if S > T:            # mic opened after adoption -> ladder was already right
            break
        # this capture straddled the adoption. Find its dispatch + any waited line.
        waited, Z = False, None
        for C2, pid2, msg2 in events[i:]:
            if pid2 != apid:
                continue
            if WAITED.search(msg2):
                waited = True
            d = DISP.search(msg2)
            if d:
                Z = d.group(1)
                break
            if C2 - C > timedelta(seconds=120):
                break
        if Z and not waited and not Z.startswith(X):
            hits.append((T, apid, X, S, Z))
        break

print(f"scanned {len(events):,} log lines, {len(adoptions)} launch adoptions")
for T, pid, X, S, Z in hits:
    print(f"  MISROUTE  adopted {X} at {T:%Y-%m-%d %H:%M:%S} [pid {pid}] "
          f"| mic opened {S:%H:%M:%S} | delivered to {Z[:8]}")
print(f"{len(hits)} misroute(s)")
sys.exit(1 if hits else 0)
