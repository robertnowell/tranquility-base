#!/bin/bash
#
# Integration test for the Codex adoption arc's full lifecycle: attach, then
# dispatch, then end -- against a REAL codex-cli session, not a stand-in.
#
# The three legs were each live-verified individually while landing (bac6855
# attach, d6694d1 send/end), but never back to back in one script, so nothing
# replays the sequence when something upstream changes. This closes that gap,
# the last item on the roadmap's "Still open, concretely" list as of 22 Aug.
#
# Seeds a real, cheap session via `codex exec` (one turn, ~20k tokens, a few
# seconds) rather than faking one: attach exercises SessionDiscovery reading
# genuine `~/.codex/sessions` rollouts and attemptCodexResume's real
# `codex resume`, which nothing synthetic can stand in for.
#
# Usage: scripts/test-codex-lifecycle.sh

set -uo pipefail
cd "$(dirname "$0")/.."
BIN="$PWD/.build/debug"

command -v codex >/dev/null 2>&1 || { echo "SKIP: no codex on this machine"; exit 0; }
swift build >/dev/null 2>&1 || { echo "build failed"; exit 1; }

OWNERSHIP="$HOME/Library/Application Support/VoiceDispatch/session-ownership.json"

PASS=0; FAIL=0
check() { # check <name> <0-if-ok>
  local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then echo "  ok    $name"; PASS=$((PASS+1))
  else echo "  FAIL  $name"; FAIL=$((FAIL+1)); fi
}

echo "codex lifecycle drill (attach -> dispatch -> end, against a real session)"

echo "→ seeding a real Codex session (codex exec, one cheap turn)"
SEED_OUT=$(codex exec "Reply with exactly: DRILL-SEED-OK. Nothing else." 2>&1)
SID=$(echo "$SEED_OUT" | grep -oE 'session id: [0-9a-f-]+' | head -1 | awk '{print $3}')
if [ -z "$SID" ]; then
  echo "✗ could not determine the seeded session id"; echo "$SEED_OUT"; exit 1
fi
echo "  session: $SID"

cleanup() {
  # Best-effort: end whatever is still attached, drop the ownership record if
  # the drill died before its own `end` step, delete the seeded session so
  # reruns don't accumulate throwaway rollouts.
  "$BIN/tbase" end "$SID" >/dev/null 2>&1
  codex delete --force "$SID" >/dev/null 2>&1
}
trap cleanup EXIT

# 1. Attach: tbase revive falls back to attemptCodexResume for a non-Claude
#    id, same path the panel's own revive takes (main.swift's revive()).
REVIVE_OUT=$("$BIN/tbase" revive "$SID" 2>&1)
echo "$REVIVE_OUT" | grep -q "^attached" 2>/dev/null
check "attach: tbase revive resumes the real session" $?

grep -q "\"$SID\"" "$OWNERSHIP" 2>/dev/null
check "attach: ownership record recorded" $?

# 2. Enroll (dispatch refuses an unenrolled session by design).
ENROLL_OUT=$("$BIN/tbase" enroll "$SID" 2>&1)
echo "$ENROLL_OUT" | grep -q "^enrolled"
check "enroll: allowlisted for dispatch" $?

# 3. Dispatch: a real message, verified landed via the Codex rollout tail
#    (not Claude Code's transcript schema -- see d6694d1's fix).
SEND_OUT=$("$BIN/tbase" send "$SID" "Reply with exactly: DRILL-SEND-OK. Nothing else." 2>&1)
echo "$SEND_OUT" | grep -q "^confirmed"
check "dispatch: tbase send lands and reads back" $?

# 4. End: the identity guard must recognize this as a genuine Codex process
#    (d6694d1's expectedCommand generalization) and take it down cleanly.
END_OUT=$("$BIN/tbase" end "$SID" 2>&1)
echo "$END_OUT" | grep -q "died on SIGTERM"
check "end: clean SIGTERM death" $?

! grep -q "\"$SID\"" "$OWNERSHIP" 2>/dev/null
check "end: ownership record removed" $?

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
