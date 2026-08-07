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

# Headless runs (claude -p from launchd or cron) have nobody at a browser —
# popping windows out of scheduled jobs is noise. The spool hook records its
# tty and lets the app decide; HERE deciding at the source is safe, because
# skipping only skips an instruction, never data.
OWN_TTY=$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')
if [ -z "$OWN_TTY" ] || [ "$OWN_TTY" = "??" ]; then
  exit 0
fi

cat <<'JSON'
{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "The user runs voice-dispatch: they hear session summaries by voice and are frequently not looking at this terminal. Anything they need to SEE — a table, an architecture diagram, a chart, an image or screenshot comparison, a mockup, any visual artifact — must NOT be rendered as terminal text. ALWAYS do both steps: (1) write it as a self-contained HTML file (inline CSS/SVG, no external assets), then (2) run `open <path>` so it appears in their browser. Creating the file without opening it is a failure — they will never find it. Keep the terminal message to a one-line pointer at what opened. Plain prose answers need no HTML."}}
JSON

exit 0
