#!/usr/bin/env python3
"""Replay a session's real turns SEQUENTIALLY, threading the goal forward.

The generic harness (replay.py) fires every record in parallel, which is right
for fields that describe one turn and wrong for the only field that does not.
`goal` is carried: turn N's answer depends on turn N-1's, so the replay has to
run in order and feed each result into the next prompt. That is the whole
difference, and it is why this is a second script rather than a flag.

Reads the live store read-only. Writes nothing but its report.

    python3 goal-replay.py --session 92b2fc45 --limit 16
"""
import argparse, json, os, sqlite3, subprocess, sys, textwrap

DB = os.path.expanduser("~/Library/Application Support/VoiceDispatch/queue.sqlite")
MODEL = "claude-haiku-4-5-20251001"


def turns(session, limit):
    """Each turn's summariser input, oldest first, joined to what it produced."""
    con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
    rows = con.execute("""
        SELECT b.atMs, b.topic, b.goal, e.lastAssistantMessage, e.cwd
        FROM brief b JOIN events e ON e.rowid = b.eventRowid
        WHERE b.sessionId LIKE ? AND e.lastAssistantMessage IS NOT NULL
        ORDER BY b.atMs ASC LIMIT ?
    """, (session + "%", limit)).fetchall()
    con.close()
    return rows


def ask(prompt, key):
    import urllib.request
    body = json.dumps({"model": MODEL, "max_tokens": 300,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=body,
        headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                 "content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read())
    return "".join(b.get("text", "") for b in data.get("content", []))


# The goal half of the production prompt, verbatim in intent. Kept here rather
# than imported so a change to Summarizer.swift shows up as a diff in the
# report, not as a silent drift between what shipped and what was measured.
INSTRUCTION = """\
You write one field for a developer running many coding-agent sessions at once.

Reply with ONLY a JSON object: {"goal": "..."}

The operator stepped away from ten running sessions and is coming back. This is
the ten words that tell them WHICH one this is and WHAT it is for.

The shape, as guidance and not a form to fill in:

    IN PROJECT X, WE ARE SOLVING PROBLEM Y.

    "In tranquility base, we're solving a bug where clicking a lamp wouldn't
    turn it off"
    "For Time Machine backups, we're working out why they take twenty four
    hours"
    "In kopi dot ai, building a repeatable process for auditing Mailchimp
    accounts"
    "In kopi dot ai, planning the August and September content calendar for
    U Vape"

BOTH halves are required.

The PROJECT is the product, repository, brand, machine or account the work is
IN, and it is the name a person would SAY OUT LOUD. It is not the directory the
agent is running from: a session started in Projects may be working in kopi dot
ai, and "Projects" tells the listener nothing. It is never a class, a file, or a
symbol either: StatusHUD is a file inside tranquility base, not a project, and
naming it answers the wrong question.

The PROBLEM is what is wrong, or what is being built. Concrete, and the thing
itself rather than the method.

These are real answers this field has produced, and all three are failures:

    "Validate lamp contrast and hue choices against aviation human factors
    standards" - names no project, and describes an activity instead of a
    problem.
    "Wire dogfood event emissions so telemetry counters actually measure what
    the app does" - which app?
    "Get robertnowell reliable backups within one year" - no system named, no
    problem stated.

Match the LENGTH of the examples above, which is the length a person says out
loud in one breath. Do not exceed them. No number is given because counting
words is not the skill; the four examples are the specification. What the extra words always are is method, tooling, or a standard's name,
and none of those is the work: "redesign lamp contrast using luminance
separation and position coding per aviation standards" says less than "fix lamp
contrast so the states are told apart at a glance". Spend the words on the
problem, never on how it is being approached. If you cannot name the project and
the problem, say the plainest true thing you can and stop.

If a goal is carried below, COPY IT VERBATIM. Do not tidy it, do not re-word
it, do not make it match this turn's topic. It is the same goal until the work
actually moves.

Replace it only when this turn shows the session is now doing something the
carried goal does not cover, and then write the NEW aim, not a summary of both.
A replacement obeys every rule above - the shape, the real project name, twelve
words, no method.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", required=True)
    ap.add_argument("--limit", type=int, default=16)
    args = ap.parse_args()

    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        sys.exit("needs ANTHROPIC_API_KEY (claude-secrets run --inject ...)")

    rows = turns(args.session, args.limit)
    if not rows:
        sys.exit("no turns for %s" % args.session)

    carried = None
    out = []
    for at, topic, old_goal, message, cwd in rows:
        prompt = INSTRUCTION
        if carried:
            prompt += ("\nThe goal this session is already carrying. KEEP IT WORD FOR "
                       "WORD unless this turn shows the work has moved to something it "
                       "does not cover:\n" + carried + "\n")
        prompt += "\nThe agent's final message this turn:\n" + (message or "")[:6000]
        try:
            reply = ask(prompt, key)
            new_goal = json.loads(reply[reply.index("{"):reply.rindex("}") + 1])["goal"]
        except Exception as exc:
            new_goal = "!! %s" % exc
        changed = carried is not None and new_goal != carried
        out.append((at, topic, old_goal, new_goal, changed))
        carried = new_goal
        print(".", end="", flush=True)
    print()

    old_distinct = len({r[2] for r in out if r[2]})
    new_distinct = len({r[3] for r in out})
    print("\nturns=%d   OLD distinct goals=%d   NEW distinct goals=%d   changes=%d\n"
          % (len(out), old_distinct, new_distinct, sum(1 for r in out if r[4])))
    for at, topic, old_goal, new_goal, changed in out:
        mark = "CHANGED" if changed else "kept"
        print("%-26s %s" % ((topic or "")[:26], mark))
        print("   was: %s" % (old_goal or "—"))
        print("   now: %s\n" % new_goal)

    with open("goal-replay-%s.json" % args.session, "w") as fh:
        json.dump([{"atMs": a, "topic": t, "old": o, "new": n, "changed": c}
                   for a, t, o, n, c in out], fh, indent=2)


if __name__ == "__main__":
    main()
