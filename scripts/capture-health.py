#!/usr/bin/env python3
"""
Two invariants, measured against the app's own log rather than a fixture.

Why this exists (19 Aug): a microphone press died, and the reply that followed
was typed into the previous agent. Both bugs are fixed and both are drilled --
but a drill runs against a panel the drill built, in a process with nothing
else happening in it. Neither failure could have been caught that way: one is a
race between two dispatches on a busy machine, and the other only appears when
a real launch takes real seconds to register. The evidence for those lives in
app.log, which already recorded every fact needed to diagnose them and which
nothing read.

So this reads it. Two questions, both answerable from lines the app already
writes, and both with a number rather than a yes:

  1. THE PRESS. Every open ends in exactly one of: audio arrived, the press
     died, the open died, or it was abandoned by its owner. A death rate is the
     measurement -- "it works" is not, because it worked 365 times in a row
     before it failed three times in ten minutes. Reported separately for the
     two shapes, because they are not the same experiment: an open that follows
     an abandon within a second IS the double-tap gesture (the first tap opens,
     releases, and the second re-opens), and it is the shape that had a
     teardown queued in front of it.

  2. THE LAUNCH. Every + NEW AGENT that registers must say where the reply
     goes -- it claimed the destination, or you had deliberately moved on. A
     launch that registers and says neither is the 19 Aug defect exactly, and
     it is silent by construction: the words simply arrive somewhere else.

Usage: scripts/capture-health.py [--since YYYY-MM-DD] [--log PATH] [--quiet]
Exit 0 clean, 1 if an invariant was violated in the window, 2 if it could not
read a log. Rates are printed always: a rate that has moved is the point, and
a gate that only speaks on zero would have said nothing all week.
"""
import argparse
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta

DEAD = ("press failed", "open failed", "never reached the machine")

LINE = re.compile(r"^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})Z \[(\d+)\]\s+(.*)$")

# The double-tap window. A re-open this soon after an abandon is one gesture,
# not two: the interval is Recorder's own verification window, which is the
# longest a queued teardown can matter for.
REOPEN_WINDOW = timedelta(seconds=1)
# How recently the app must have been speaking for playback to plausibly still
# own the hardware. Deliberately generous: this is a reported correlate, never
# a verdict -- see the note under the table.
SPEAKING_WINDOW = timedelta(seconds=2)
# A press that never reached the machine is judged against the abandon that
# preceded it more loosely than a live open is: it carries no timestamp of its
# own beyond the moment the verdict fired, which is one verification window
# after the press itself.
STILLBIRTH_WINDOW = timedelta(seconds=3)


def parse(paths):
    for path in paths:
        if not os.path.exists(path):
            continue
        with open(path, "r", errors="replace") as handle:
            for raw in handle:
                match = LINE.match(raw.rstrip("\n"))
                if not match:
                    continue
                day, clock, pid, message = match.groups()
                stamp = datetime.strptime(f"{day}T{clock}", "%Y-%m-%dT%H:%M:%S")
                yield stamp, day, pid, message


class Open:
    __slots__ = ("stamp", "day", "pid", "after_abandon", "while_speaking", "outcome")

    def __init__(self, stamp, day, pid, after_abandon, while_speaking):
        self.stamp = stamp
        self.day = day
        self.pid = pid
        self.after_abandon = after_abandon
        self.while_speaking = while_speaking
        self.outcome = "unresolved"


def collect(events):
    """One pass, segmented by pid: thirteen launches wrote to this log in a day
    and an open in one process cannot be resolved by a line from another."""
    opens, launches = [], []
    live = {}          # pid -> the open still awaiting an outcome
    last_abandon = {}  # pid -> when this process last abandoned an open
    last_speech = {}   # pid -> when audio was last being produced
    pending_launch = {}  # pid -> the launch awaiting a routing verdict

    for stamp, day, pid, message in events:
        if message.startswith("11labs:") or message.startswith("announce:") \
                or message.startswith("earcon:"):
            last_speech[pid] = stamp

        if "(capture requested)" in message:
            prior = last_abandon.get(pid)
            spoke = last_speech.get(pid)
            current = Open(
                stamp, day, pid,
                after_abandon=prior is not None and stamp - prior <= REOPEN_WINDOW,
                while_speaking=spoke is not None and stamp - spoke <= SPEAKING_WINDOW)
            # An open that never resolved (the process died mid-press, the log
            # rolled) is counted as unresolved, never as a pass.
            live[pid] = current
            opens.append(current)
        elif "(audio arrived)" in message:
            if pid in live:
                live.pop(pid).outcome = "captured"
        elif "(abandoned)" in message:
            last_abandon[pid] = stamp
            if pid in live:
                live.pop(pid).outcome = "abandoned"
        elif message.startswith("mic: press failed"):
            if pid in live:
                live.pop(pid).outcome = "press failed"
            else:
                # THE SIGNATURE, and the reason this is measured from absence.
                # A press that dies this way logged no "capture requested" at
                # all: `start` only dispatches, and the block that would have
                # asked the machine to open never ran inside the verification
                # window. So the defect appears in the log as a death with no
                # birth, and any counter keyed on opens scores it as nothing
                # happening. It is recorded here as its own kind.
                stillborn = Open(stamp, day, pid, after_abandon=(
                    last_abandon.get(pid) is not None
                    and stamp - last_abandon[pid] <= STILLBIRTH_WINDOW),
                    while_speaking=(last_speech.get(pid) is not None
                                    and stamp - last_speech[pid] <= SPEAKING_WINDOW))
                stillborn.outcome = "never reached the machine"
                opens.append(stillborn)
        elif message.startswith("mic: open failed"):
            if pid in live:
                live.pop(pid).outcome = "open failed"

        if "newSession: launched" in message:
            pending_launch[pid] = (stamp, day)
        elif message.startswith("launch: replies now go to"):
            pending_launch.pop(pid, None)
            launches.append((day, "claimed"))
        elif message.startswith("launch:") and "moved on" in message:
            pending_launch.pop(pid, None)
            launches.append((day, "you moved on"))
        elif "no session registered" in message:
            pending_launch.pop(pid, None)
            launches.append((day, "never registered"))
        elif message.startswith("greeting: NOT bound"):
            # Pre-fix builds stop here and say nothing else. Post-fix builds
            # have already logged their routing verdict above, so this only
            # reports an unrouted launch on a build that had the bug.
            if pending_launch.pop(pid, None):
                launches.append((day, "UNROUTED"))
    return opens, launches


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=os.path.expanduser(
        "~/Library/Application Support/VoiceDispatch/app.log"))
    ap.add_argument("--since", help="YYYY-MM-DD; default: the whole log")
    ap.add_argument("--quiet", action="store_true", help="verdict lines only")
    args = ap.parse_args()

    paths = [args.log + ".1", args.log]
    if not any(os.path.exists(p) for p in paths):
        print(f"x no log at {args.log}", file=sys.stderr)
        return 2
    if args.since:
        # The rolled log is 32MB of days nobody asked about, and a check that
        # runs every two hours should not re-read them every time. A file whose
        # last write predates the window cannot contain a line inside it.
        cutoff = datetime.strptime(args.since, "%Y-%m-%d")
        paths = [p for p in paths if not os.path.exists(p)
                 or datetime.fromtimestamp(os.path.getmtime(p)) >= cutoff]

    opens, launches = collect(parse(paths))
    if args.since:
        opens = [o for o in opens if o.day >= args.since]
        launches = [l for l in launches if l[0] >= args.since]

    # THE PRESS, by day and by shape.
    by_day = defaultdict(lambda: defaultdict(int))
    for o in opens:
        shape = "after an abandon" if o.after_abandon else "on its own"
        by_day[o.day][(shape, o.outcome)] += 1

    dead = [o for o in opens if o.outcome in DEAD]
    if not args.quiet:
        print("THE PRESS — every open, by the shape that produced it\n")
        print(f"  {'day':<12} {'shape':<18} {'opens':>6} {'dead':>5} {'rate':>7}")
        for day in sorted(by_day):
            for shape in ("on its own", "after an abandon"):
                total = sum(n for (s, _), n in by_day[day].items() if s == shape)
                if not total:
                    continue
                bad = sum(n for (s, o), n in by_day[day].items()
                          if s == shape and o in DEAD)
                print(f"  {day:<12} {shape:<18} {total:>6} {bad:>5} "
                      f"{100.0 * bad / total:>6.1f}%")
        speaking = sum(1 for o in dead if o.while_speaking)
        if dead:
            print(f"\n  {speaking} of {len(dead)} dead presses had the app "
                  "speaking within 2s.")
            print("  Reported, not concluded: playback is common during a "
                  "reply, so this is a lead to measure, never a cause.")

    # THE LAUNCH.
    verdicts = defaultdict(int)
    for _, verdict in launches:
        verdicts[verdict] += 1
    if not args.quiet:
        print("\nTHE LAUNCH — where the reply went after + NEW AGENT\n")
        if not launches:
            print("  no launches in the window")
        for verdict, count in sorted(verdicts.items()):
            print(f"  {count:>4}  {verdict}")

    unrouted = verdicts.get("UNROUTED", 0)
    print()
    if dead:
        print(f"x {len(dead)} dead press(es) of {len(opens)} opens "
              f"({100.0 * len(dead) / max(len(opens), 1):.1f}%)")
    else:
        print(f"/ no dead presses in {len(opens)} opens")
    if unrouted:
        print(f"x {unrouted} launch(es) registered with the reply routed nowhere")
    else:
        print(f"/ every registered launch said where the reply went "
              f"({len(launches)} launches)")
    return 1 if (dead or unrouted) else 0


if __name__ == "__main__":
    sys.exit(main())
