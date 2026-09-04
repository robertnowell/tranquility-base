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

# WHERE, and the reason the where matters.
#
# The instruction said to write a page and open it, and never said where. So
# sessions wrote wherever they happened to be and the hub could not find the
# result: ~/Projects/contract-proof/brief-coframe.html (168KB) and
# ~/Projects/coframe-issues/index.html (164KB) were both real reports recorded
# nowhere.
#
# The first answer to that was to glob likely directories and read the
# transcript to work out who wrote what. That is the wrong end: attribution only
# needs guessing because nothing was ever agreed. A page written to
# ~/Documents/agents/<agent-id>/<report-slug>.html states its own author in its
# own path, so there is nothing to infer -- and that is beside the agent's own
# hub, which is the page that lists it.
# NAME THE DIRECTORY. DO NOT DESCRIBE HOW TO DERIVE IT.
#
# This emitted the literal string "~/Documents/agents/$AGENT/" three times and
# then explained that $AGENT is "the first dash-separated piece of your session
# id". Nothing ever substituted it: the heredoc is quoted, and this hook had
# never once read the session id off its own payload -- zero occurrences in its
# entire history -- even though every SessionStart payload carries it.
#
# So the instruction was a rule to apply rather than a path to use, and the one
# concrete eight-hex id a session actually sees during a turn is usually
# somebody else's: whatever directory it has been reading. On 02 Sep session
# 95d165f8 wrote two of its own reports into 4394c0ec's directory, the archive
# read authorship off the path, and both hubs listed them. Robert, on the
# defensive layers that followed: "this seems a bit like a hat on a hat... we
# just need to get the mechanism right... somehow we had context that wasn't
# clear about which agent directory the current agent should put it in."
#
# It is not a rule any more. The path is resolved here, from the payload, and
# printed in full.
PAYLOAD=$(cat)
AGENT=$(printf '%s' "$PAYLOAD" | python3 -c 'import json,sys
try:
    print((json.load(sys.stdin).get("session_id") or "").split("-")[0])
except Exception:
    print("")' 2>/dev/null)

# With no id there is no honest path to print, so it falls back to the rule
# rather than inventing a directory. Silence would be worse: a session with no
# instruction writes wherever it happens to be, which is the failure this hook
# was built for.
if [ -n "$AGENT" ]; then
  DIR="$HOME/Documents/agents/$AGENT"
  WHOSE="This is YOUR directory and nobody else's -- $AGENT is your own session id. NEVER write a page into another agent's directory: the archive reads authorship from the path, so a page filed under somebody else's id says THEY wrote it, lands on THEIR hub, and its Discuss button opens THEIR conversation."
else
  DIR="$HOME/Documents/agents/<first dash-separated piece of your session id>"
  WHOSE="Never write a page into another agent's directory."
fi

python3 - "$DIR" "$WHOSE" "${AGENT:-<your session id>}" <<'PYCTX' 2>/dev/null || true
import json, sys
directory, whose, agent = sys.argv[1], sys.argv[2], sys.argv[3]
text = (
    "The user runs Tranquility Base: they hear sessions by voice and are usually "
    "NOT looking at this terminal. TREAT THE TERMINAL AS INVISIBLE. Anything you "
    "leave there, they will probably never see.\n\n"
    "Whenever you PRESENT A RESULT to them -- a finding, evidence, a comparison, a "
    "recommendation, numbers they are meant to weigh, anything they need in order "
    "to make a decision -- it goes on a page, not in the terminal. The test is NOT "
    "'is this visual?'. The test is 'is this FOR THEM, rather than working notes "
    "for me?'. A findings table with an argued conclusion and three options at the "
    "end is exactly this, even though it is prose and numbers rather than a chart. "
    "If you are about to end a turn by asking them to choose something, the thing "
    "they are choosing between belongs on a page.\n\n"
    "WHERE IT GOES: " + directory + "/<report-slug>.html -- one file per report, a "
    "short slug naming the subject. " + whose + " That directory is where your agent "
    "hub lives, so a page written there is listed on your hub automatically and "
    "needs nothing else from you. Do not touch index.html in it -- that is the hub "
    "itself and the app writes it.\n\n"
    "THE PAGE SAYS WHO WROTE IT. Put this in its head, first line of metadata:\n"
    "  <meta name=\"intranet:session\" content=\"" + agent + "\">\n"
    "That one line is what makes the page yours. Without it the archive falls "
    "back to assuming whoever owns the directory wrote it, which is how reports "
    "have ended up on the wrong agent's hub with the wrong Discuss button.\n\n"
    "ALWAYS ALL THREE STEPS: (1) write " + directory + "/<slug>.html, self-contained "
    "-- inline CSS/SVG, no external assets, and a favicon; (2) run `open` on it; (3) "
    "leave the terminal a one-line pointer at what opened, nothing more. Writing "
    "without opening is a failure -- they will never find it.\n\n"
    "If the page is also going OUTSIDE -- to a customer or a prospect -- build it "
    "with the share-as-page skill instead, which deploys it, and still write or link "
    "it under your agent directory so it is on your hub.\n\n"
    "What does NOT need a page: conversational replies, progress narration, a "
    "one-line answer, and your own intermediate reasoning. When in doubt, ask "
    "whether you would be happy for them to miss it entirely -- if not, it is a page."
)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart", "additionalContext": text}}))
PYCTX

exit 0
