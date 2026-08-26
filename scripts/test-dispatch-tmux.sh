#!/bin/bash
#
# Integration test for the tmux dispatch leg — the twin of test-dispatch.sh.
#
# Launches `tbase-test-target` inside a detached tmux session on a throwaway
# server and drives the full closed loop — pane resolution, mode clearing,
# paste, landing verification, the separate Return, read-back — with no Claude
# Code session involved. Then the exact-once section: deliveries under an
# adversary that shoves the pane into copy-mode at random, the condition that
# destroys naively injected text (measured 19 Aug; 100/100 in the pre-build
# validation, replayed here at every deploy so the contract cannot rot the
# way the AppleScript watcher's did, twice).
#
# Usage: scripts/test-dispatch-tmux.sh

set -uo pipefail
cd "$(dirname "$0")/.."
BIN="$PWD/.build/debug"

swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }
command -v tmux >/dev/null 2>&1 || TMUX_BIN=""
TMUX_BIN=$(command -v tmux || echo /usr/local/bin/tmux)
[ -x "$TMUX_BIN" ] || { echo "SKIP: no tmux on this machine"; exit 0; }

export TB_TMUX_SOCKET="tbdrill-$$"
SID="dispatch-tmux-$$"
TRANSCRIPT="$HOME/Library/Application Support/VoiceDispatch/test-targets/$SID.jsonl"
T() { "$TMUX_BIN" -L "$TB_TMUX_SOCKET" "$@"; }

cleanup() {
  rm -f "$PWD/.tmux-drill-adversary" 2>/dev/null
  T kill-server 2>/dev/null
  pkill -f "tbase-test-target $SID" 2>/dev/null
  rm -f "$TRANSCRIPT"
}
trap cleanup EXIT

# NB: the drill server uses the default socket dir; only the app's own "tb"
# socket lives under Application Support. TB_TMUX_SOCKET makes send-raw-tmux
# address this throwaway server instead.
T new-session -d -s target -x 200 -y 50 "$BIN/tbase-test-target $SID" || {
  echo "harness failed to start"; exit 1; }
sleep 2
PANE=$(T display -p -t target '#{pane_id}')
PID=$(pgrep -f "tbase-test-target $SID" | head -1)
[ -z "$PID" ] && { echo "harness process not found"; exit 1; }

PASS=0; FAIL=0
expect() { # expect <name> <expected-exit> <text...>
  local name="$1" want="$2"; shift 2
  "$BIN/tbase" send-raw-tmux "$PID" "$PANE" "$TRANSCRIPT" "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ok    $name"; PASS=$((PASS+1))
  else
    echo "  FAIL  $name (exit $got, wanted $want)"; FAIL=$((FAIL+1))
  fi
}

LONG=$(python3 -c "print('Reply. ' + 'The migration has not run against live so a deploy would fail. ' * 20)")

echo "tmux dispatch integration tests (harness pid=$PID pane=$PANE socket=$TB_TMUX_SOCKET)"
expect "short text confirms"                 0 "Yes go ahead and run the migration"
expect "long text confirms (>1024 bytes)"    0 "$LONG"
expect "multi-line collapses to one turn"    0 "$(printf 'One.\nTwo.\nThree.')"
expect "quotes and backslashes survive"      0 'He said "ship it" and the path is C:\temp\x'

# Delivery INTO copy-mode: the loop must clear the mode and still land it.
T copy-mode -t "$PANE"
expect "delivery into copy-mode confirms"    0 "Mode was on when this was sent"

# The watermark regression: the SAME payload delivered twice must land twice.
# Before the 19 Aug watermark fix, the second send false-confirmed against the
# first one's transcript record without ever pasting.
"$BIN/tbase" send-raw-tmux "$PID" "$PANE" "$TRANSCRIPT" "yes" >/dev/null 2>&1
RC1=$?
"$BIN/tbase" send-raw-tmux "$PID" "$PANE" "$TRANSCRIPT" "yes" >/dev/null 2>&1
RC2=$?
YES_COUNT=$(grep -c '"content":"yes"' "$TRANSCRIPT" 2>/dev/null || echo 0)
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$YES_COUNT" -eq 2 ]; then
  echo "  ok    repeated payload lands twice (watermark)"; PASS=$((PASS+1))
else
  echo "  FAIL  repeated payload (rc=$RC1/$RC2 landed=$YES_COUNT wanted 2)"; FAIL=$((FAIL+1))
fi

# Failure paths.
"$BIN/tbase" send-raw-tmux 999999 "$PANE" "$TRANSCRIPT" x >/dev/null 2>&1
[ $? -eq 5 ] && { echo "  ok    dead pid fails closed"; PASS=$((PASS+1)); } \
             || { echo "  FAIL  dead pid"; FAIL=$((FAIL+1)); }

"$BIN/tbase" send-raw-tmux "$PID" "%999" "$TRANSCRIPT" x >/dev/null 2>&1
[ $? -eq 5 ] && { echo "  ok    unknown pane fails closed"; PASS=$((PASS+1)); } \
             || { echo "  FAIL  unknown pane"; FAIL=$((FAIL+1)); }

# Exact-once under adversarial copy-mode churn. Ten messages here rather than
# the validation's hundred: this replays at every deploy, and the class of
# regression it catches (mode races, paste loss, double-delivery) shows up in
# ten or it shows up in none.
touch "$PWD/.tmux-drill-adversary"
( while [ -f "$PWD/.tmux-drill-adversary" ]; do
    case $((RANDOM % 3)) in
      0) T copy-mode -t "$PANE" 2>/dev/null ;;
      1) T send-keys -t "$PANE" -X -N 3 scroll-up 2>/dev/null ;;
      2) T send-keys -t "$PANE" -X cancel 2>/dev/null ;;
    esac
    sleep 0.$((RANDOM % 3 + 1))
  done ) &
EXACT_FAIL=0
EXACT_WHY=""
for i in $(seq 1 10); do
  OUT=$("$BIN/tbase" send-raw-tmux "$PID" "$PANE" "$TRANSCRIPT" "exact-once probe $i" 2>&1) \
    || { EXACT_FAIL=$((EXACT_FAIL+1)); EXACT_WHY="probe $i: $(echo "$OUT" | tail -1)"; }
done
rm -f "$PWD/.tmux-drill-adversary"; sleep 1
# DISTINCT probes, not lines. A line count cannot tell nine-plus-a-duplicate
# from ten, and those are opposite verdicts: one is a lost message and a
# double-send, the other is a clean run. Counting lines hid exactly that for
# as long as this case has existed.
DISTINCT=$(grep -o "exact-once probe [0-9]*" "$TRANSCRIPT" 2>/dev/null | sort -u | wc -l | tr -d ' ')
TOTAL=$(grep -o "exact-once probe [0-9]*" "$TRANSCRIPT" 2>/dev/null | wc -l | tr -d ' ')
DUPES=$((TOTAL - DISTINCT))
if [ "$EXACT_FAIL" -eq 0 ] && [ "$DISTINCT" -eq 10 ] && [ "$DUPES" -eq 0 ]; then
  echo "  ok    exact-once under copy-mode churn (10/10 distinct, no duplicates)"; PASS=$((PASS+1))
else
  echo "  FAIL  exact-once (errors=$EXACT_FAIL distinct=$DISTINCT dupes=$DUPES wanted 10/0)"
  [ -n "$EXACT_WHY" ] && echo "        last error — $EXACT_WHY"
  FAIL=$((FAIL+1))
fi

echo
echo "tmux dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
