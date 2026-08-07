#!/bin/bash
#
# Integration test for the dispatch leg.
#
# Launches `tbase-test-target` in a throwaway Terminal.app tab and drives the
# full path — tty lookup, AppleScript injection, the separate Return, read-back
# verification — with no Claude Code session involved. Safe to run repeatedly.
#
# Usage: scripts/test-dispatch.sh

set -uo pipefail
cd "$(dirname "$0")/.."
BIN="$PWD/.build/debug"

swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }

SID="dispatch-it-$$"
TRANSCRIPT="$HOME/Library/Application Support/VoiceDispatch/test-targets/$SID.jsonl"

cleanup() {
  pkill -f "tbase-test-target $SID" 2>/dev/null
  osascript -e "tell application \"Terminal\" to close (every window whose name contains \"$SID\")" 2>/dev/null
  rm -f "$TRANSCRIPT"
}
trap cleanup EXIT

osascript -e "tell application \"Terminal\" to do script \"$BIN/tbase-test-target $SID\"" >/dev/null
sleep 3

PID=$(pgrep -f "tbase-test-target $SID" | head -1)
[ -z "$PID" ] && { echo "harness failed to start"; exit 1; }
TTY="/dev/$(ps -o tty= -p "$PID" | tr -d ' ')"

PASS=0; FAIL=0
expect() { # expect <name> <expected-exit> <args...>
  local name="$1" want="$2"; shift 2
  "$BIN/tbase" send-raw "$PID" "$TTY" "$TRANSCRIPT" "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ok    $name"; PASS=$((PASS+1))
  else
    echo "  FAIL  $name (exit $got, wanted $want)"; FAIL=$((FAIL+1))
  fi
}

LONG=$(python3 -c "print('Reply. ' + 'The migration has not run against live so a deploy would fail. ' * 20)")

echo "dispatch integration tests (harness pid=$PID tty=$TTY)"
expect "short text confirms"                 0 "Yes go ahead and run the migration"
expect "long text confirms (>1024 bytes)"    0 "$LONG"
expect "multi-line collapses to one turn"    0 "$(printf 'One.\nTwo.\nThree.')"
expect "quotes and backslashes survive"      0 'He said "ship it" and the path is C:\temp\x'

# Failure paths, checked separately because they use a different target.
"$BIN/tbase" send-raw 999999 "$TTY" "$TRANSCRIPT" x >/dev/null 2>&1
[ $? -eq 5 ] && { echo "  ok    dead pid fails closed"; PASS=$((PASS+1)); } \
             || { echo "  FAIL  dead pid"; FAIL=$((FAIL+1)); }

"$BIN/tbase" send-raw "$PID" /dev/ttys999 "$TRANSCRIPT" x >/dev/null 2>&1
[ $? -eq 5 ] && { echo "  ok    unknown tty fails closed"; PASS=$((PASS+1)); } \
             || { echo "  FAIL  unknown tty"; FAIL=$((FAIL+1)); }

# Verify what actually landed, not just the exit codes.
LINES=$(wc -l < "$TRANSCRIPT" | tr -d ' ')
if [ "$LINES" -eq 4 ]; then
  echo "  ok    exactly 4 turns recorded (no fragmentation)"; PASS=$((PASS+1))
else
  echo "  FAIL  expected 4 turns, got $LINES"; FAIL=$((FAIL+1))
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
