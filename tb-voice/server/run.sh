#!/bin/bash
# Keys come from the macOS Keychain via claude-secrets; nothing is written to .env.
#
# claude-secrets run buffers the child's stdout into a JSON envelope until exit,
# and stdout is the app's pipe when the app hosts this process. So the bot writes
# its one-line-per-event stream to a FIFO (TB_EVENTS), and this outer shell, which
# is NOT wrapped, relays the FIFO to stdout as it arrives. The log goes to bot.log.
cd "$(dirname "$0")"
# One manager at a time. A relaunch of the app kills the app, not its child, and
# an orphaned manager keeps the mic and writes to a pipe nobody reads.
pgrep -f "tb-voice/server/.venv/bin/python bot.py" | grep -v "^$$\$" | xargs -r kill 2>/dev/null
export PATH="$HOME/.local/bin:$HOME/.claude/plugins/cache/claude-secrets-marketplace/claude-secrets/1.0.0/bin:$PATH"
FIFO="$(mktemp -u /tmp/tb-voice-events.XXXXXX)"
mkfifo "$FIFO"
trap 'rm -f "$FIFO"' EXIT
cat "$FIFO" &
exec 3>"$FIFO"   # keep the writer open so cat does not see EOF between events
exec claude-secrets run \
  --inject general-compute-api-key=GC_API_KEY \
  --inject ASSEMBLYAI_API_KEY=ASSEMBLYAI_API_KEY \
  --inject ELEVENLABS_API_KEY=ELEVENLABS_API_KEY \
  --inject typesafe-jev-api-key=JEV_API_KEY \
  -- env TB_EVENTS="$FIFO" uv run bot.py "$@"
