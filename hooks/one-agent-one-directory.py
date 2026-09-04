#!/usr/bin/env python3
"""Refuse to write a page into another agent's directory.

WHY THIS AND NOT ATTRIBUTION. For two days every hub failure has been the same
one: a page landed in the wrong agent's directory and the archive then tried to
work out who wrote it — from a command, a timestamp, a transcript, whatever was
to hand. Six mechanisms, six different wrong answers, one page on four hubs.
Robert, 03 Sep, on the seventh idea: "matching by timestamps, that still seems
risky and lossy and, frankly, kind of janky."

He is right. There is no attribution problem here; there is a WRITE-LOCATION
problem. `~/Documents/agents/<slug>/` already names its owner exactly, with no
inference at all — so the fix is to make the wrong write impossible rather than
to guess afterwards who made it.

WHY PARSING IS FINE HERE AND WAS NOT THERE. This still has to spot the target of
a shell redirect, which is the same reading that went wrong all week. What
changes is which way a mistake falls:

  recording  a false positive is a silent lie that lands on somebody's hub
  denying    a false positive is a blocked command the session sees at once,
             and a false negative is exactly today's behaviour

So it refuses only when it is SURE — a declared file_path, or a redirect target
it can see — and stays out of the way otherwise.

Escape: TB_ALLOW_CROSS_AGENT_WRITE=1 for deliberate maintenance (moving a
misfiled page to its rightful owner, repairing a stamp). Explicit, so it cannot
happen by accident.
"""
import json
import os
import re
import sys

AGENTS = os.path.expanduser("~/Documents/agents")
SLUG = re.compile(r"^[0-9a-f]{8}$")
# A page path inside somebody's agent directory, as it appears in a command.
PATH = (r"(?:~|\$HOME|/Users/[^/\s'\"]+)/Documents/agents/([0-9a-f]{8})/"
        r"[^\s'\"<>|;)]+\.(?:html|htm|md)")
REDIRECT = re.compile(r">>?\s*['\"]?" + PATH)
COPY = re.compile(r"\b(?:cp|mv|install|rsync)\s+[^|;&]*?\s" + PATH)
TEE = re.compile(r"\btee\s+(?:-\S+\s+)*['\"]?" + PATH)


def targets(payload):
    """Directories this call would WRITE into. Empty when it cannot be sure."""
    inp = payload.get("tool_input") or {}
    declared = inp.get("file_path") or ""
    if isinstance(declared, str) and declared:
        path = os.path.realpath(os.path.expanduser(declared))
        if path.startswith(AGENTS + os.sep):
            rest = path[len(AGENTS) + 1:].split(os.sep)
            return [rest[0]] if rest and SLUG.match(rest[0]) else []
        return []
    cmd = inp.get("command") or ""
    if not isinstance(cmd, str):
        return []
    found = []
    for rx in (REDIRECT, COPY, TEE):
        found += rx.findall(cmd)
    return [d for d in found if SLUG.match(d)]


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0                      # never block on a payload we cannot read
    # THE ESCAPE HAS TO BE IN THE COMMAND, not in the environment.
    #
    # A PreToolUse hook is spawned by the harness with the harness's own
    # environment, so `TB_ALLOW_CROSS_AGENT_WRITE=1 cmd` never reaches it —
    # discovered within a minute of shipping, when the guard blocked the very
    # command meant to bypass it, and then blocked the command that would have
    # fixed the bypass. The marker is read out of the command text instead,
    # which is the one thing the payload does carry.
    inp = payload.get("tool_input") or {}
    if "TB_ALLOW_CROSS_AGENT_WRITE=1" in str(inp.get("command") or ""):
        return 0
    if os.environ.get("TB_ALLOW_CROSS_AGENT_WRITE") == "1":
        return 0
    mine = (payload.get("session_id") or "")[:8]
    if not SLUG.match(mine):
        return 0                      # no id, no opinion
    others = sorted({d for d in targets(payload) if d != mine})
    if not others:
        return 0
    other = others[0]
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            f"That path is agent {other}'s directory, not yours. Yours is "
            f"{AGENTS}/{mine}/ — write the page there.\n\n"
            "The archive reads authorship from the path: a page under another "
            "agent's id says THAT agent wrote it, lands on their hub, and its "
            "Discuss button opens their conversation. This is refused rather "
            "than corrected afterwards because every attempt to work out who "
            "really wrote a misfiled page has been wrong in a new way.\n\n"
            "Moving a page to its rightful owner on purpose? Prefix the command "
            "with TB_ALLOW_CROSS_AGENT_WRITE=1."),
    }}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
