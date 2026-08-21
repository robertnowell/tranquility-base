#!/bin/bash
#
# visual-output hook — runs on Claude Code SessionStart.
#
# voice-dispatch turns the terminal into an away-channel: you HEAR sessions
# finish and answer by voice, often without looking at the tab. Terminal-
# rendered visuals — ASCII tables, box-drawn architecture diagrams, screenshot
# dumps — therefore go unseen. This hook teaches every interactive session the
# house rule: anything the user needs to SEE becomes an HTML file opened in
# the browser. Two steps, always: (1) write the file, (2) `open` it.
# (A companion skill teaching how to compose these pages comes later; the hook
# only sets the contract.)
#
# Contract (same as tbase-hook.sh):
#   1. NEVER block. This runs at session start.
#   2. NEVER fail. Always exit 0, whatever happens.
#   3. Emit the instruction on stdout; touch nothing else.
#
# Install: hooks.SessionStart in ~/.claude/settings.json (tbase install-hooks).

set -u

# Headless runs (claude -p from launchd or cron) have nobody at a browser --
# popping windows out of scheduled jobs is noise.
#
# THE TTY TEST SUPPRESSED EVERY SESSION, INCLUDING YOURS. A hook is spawned
# without a controlling terminal whoever started it, so `ps -o tty=` reports
# `??` or nothing for an interactive session exactly as it does for cron: this
# guard exited 0 every time and the instruction below has never reached a
# single session on this machine. Measured by running the hook the way Claude
# Code runs it -- zero bytes out.
#
# What that cost: sessions rendered visual work as terminal text because they
# were never told not to. A full statistical power matrix went inline into a
# terminal on 21 Aug, in a conversation whose whole point was a decision to
# put in front of a client.
#
# The same dead discriminator as open-issues item 1, which concluded "the tty
# approach is dead" and moved to the entrypoint. That conclusion shipped in
# SessionDiscovery.isHeadless and never reached this file. CLAUDE_CODE_ENTRYPOINT
# is `cli` for a terminal someone is sitting at and `sdk-cli` for `claude -p`,
# a cron job or the replay harness -- positive evidence, and the same string
# the app already filters the grid on.
#
# Unknown is treated as INTERACTIVE, deliberately: the cost of a stray
# instruction is one wasted sentence, and the cost of suppressing it is what
# this comment is about.
if [ "${CLAUDE_CODE_ENTRYPOINT:-cli}" = "sdk-cli" ]; then
  exit 0
fi

cat <<'JSON'
{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "The user runs voice-dispatch: they hear session summaries by voice and are frequently not looking at this terminal. Anything they need to SEE — a table, an architecture diagram, a chart, an image or screenshot comparison, a mockup, any visual artifact — must NOT be rendered as terminal text. ALWAYS do both steps: (1) write it as a self-contained HTML file (inline CSS/SVG, no external assets), then (2) run `open <path>` so it appears in their browser. Creating the file without opening it is a failure — they will never find it. Keep the terminal message to a one-line pointer at what opened. Plain prose answers need no HTML."}}
JSON

exit 0
