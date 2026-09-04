#!/usr/bin/env bash
#
# Prove, on a real machine, that a launch which never registers ends with a
# window in front of the user rather than a card claiming it started.
#
# This is the one leg of the 3 Sep repair that cannot be unit-tested: the
# decision lives in `newSession`, and reaching it needs a real pane, a real
# 30-second budget, and a real click on New session. Everything else about
# that repair is covered by LaunchReadinessTests and ClaudeTrustTests.
#
# The trick is a harness profile that has never been onboarded. Claude Code
# stops such a pane on its theme picker, which is a screen no needle in this
# app knows and whose syntax sample happens to contain the word "Claude" —
# the exact shape that used to be reported as a successful launch.
#
# Restores the agent command on every exit path, including Ctrl-C.
set -uo pipefail

SUPPORT="$HOME/Library/Application Support/VoiceDispatch"
CMD_FILE="$SUPPORT/agent-command.json"
LOG="$SUPPORT/app.log"
BACKUP="$(mktemp)"
PROFILE="$(mktemp -d)"
WRAPPER="$(mktemp)"

restore() {
  [ -s "$BACKUP" ] && cp "$BACKUP" "$CMD_FILE"
  rm -rf "$PROFILE" "$WRAPPER" "$BACKUP"
  echo
  echo "restored your agent command:"
  "$(dirname "$0")/../.build/debug/tbase" agent-command 2>/dev/null | head -1
}
trap restore EXIT INT TERM

command -v claude >/dev/null || CLAUDE="$HOME/.local/bin/claude"
CLAUDE="${CLAUDE:-$(command -v claude)}"
[ -x "$CLAUDE" ] || { echo "no claude binary found"; exit 1; }

cp "$CMD_FILE" "$BACKUP" 2>/dev/null || { echo "no agent-command.json to back up"; exit 1; }

# A wrapper script, not an inline `VAR=x claude` prefix: the launcher composes
# one shell string and an env assignment in front of the binary does not
# survive it. Found the hard way, 3 Sep, when the pane died on launch instead
# of blocking.
cat > "$WRAPPER" <<WRAP
#!/bin/bash
export CLAUDE_CONFIG_DIR="$PROFILE"
exec "$CLAUDE" --dangerously-skip-permissions
WRAP
chmod +x "$WRAPPER"

python3 - "$CMD_FILE" "$WRAPPER" <<'PY'
import json, sys
p, wrapper = sys.argv[1], sys.argv[2]
d = json.load(open(p))
if isinstance(d, dict) and "commands" in d:
    d["commands"]["claude-code"] = wrapper
elif isinstance(d, dict) and "command" in d:
    d["command"] = wrapper
else:
    d = {"command": wrapper}
json.dump(d, open(p, "w"))
print("agent command pointed at a first-run profile")
PY

MARK=$(wc -l < "$LOG" | tr -d ' ')
echo
echo "───────────────────────────────────────────────────────────────"
echo "  NOW: right-click the Tranquility Base menu bar icon and"
echo "       choose  New session."
echo
echo "  Watching the log for 60s. Expected, in order:"
echo "    launcher: nothing registered in <dir> after 30s ..."
echo "    showPane: opened a window on <tty> ..."
echo "    launch question: <what the pane says>"
echo "───────────────────────────────────────────────────────────────"
echo

for _ in $(seq 1 60); do
  sleep 1
  if tail -n +$((MARK + 1)) "$LOG" 2>/dev/null | grep -q "launch question:"; then break; fi
done

echo "── log since you clicked ──"
tail -n +$((MARK + 1)) "$LOG" | grep -E "launcher:|showPane:|launch question:" || echo "(nothing — did the click land?)"

echo
if tail -n +$((MARK + 1)) "$LOG" | grep -q "showPane: opened a window"; then
  echo "PASS: the blocked launch opened a window and asked you."
elif tail -n +$((MARK + 1)) "$LOG" | grep -q "launch question:"; then
  echo "PARTIAL: it asked you, but no window opened."
  echo "         Grant Automation for Terminal, or check the card's wording."
else
  echo "FAIL or not run: no launch question in the log."
fi
