#!/bin/bash
# Keys come from the macOS Keychain via claude-secrets; nothing is written to .env.
#
# claude-secrets run buffers the child's stdout into a JSON envelope until exit,
# and stdout is the app's pipe when the app hosts this process. So the bot writes
# its one-line-per-event stream to a FIFO (TB_EVENTS), and this outer shell, which
# is NOT wrapped, relays the FIFO to stdout as it arrives. The log goes to bot.log.
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
FIFO="$(mktemp -u /tmp/tb-voice-events.XXXXXX)"
mkfifo "$FIFO"
trap 'rm -f "$FIFO"' EXIT
cat "$FIFO" &
exec 3>"$FIFO"   # keep the writer open so cat does not see EOF between events
exec claude-secrets run \
  --inject general-compute-api-key=GC_API_KEY \
  --inject gradium-api-key=GRADIUM_API_KEY \
  --inject typesafe-jev-api-key=JEV_API_KEY \
  -- env TB_EVENTS="$FIFO" uv run bot.py "$@"
