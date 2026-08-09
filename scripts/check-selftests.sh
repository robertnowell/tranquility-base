#!/bin/bash
#
# Read the verdicts the app already writes at every launch, and fail if any
# self-test failed.
#
# Why this exists: `Sources/TranquilityApp/` is the most-edited code in the repo
# (main.swift and StatusHUD.swift lead by a wide margin) and the least covered —
# `swift test` proves Core, and no unit test can reach a panel that needs a real
# window server. The launch self-tests were already filling that gap: 46
# assertions run on every start. Nothing read them. A drill that nobody checks
# is a comment with a runtime cost.
#
# Usage: scripts/check-selftests.sh [logfile] [since-epoch-seconds]
#   Default log: the app's own. Default window: the last 120 seconds, so a
#   passing launch from an hour ago cannot vouch for the build running now.
set -uo pipefail

LOG="${1:-$HOME/Library/Application Support/VoiceDispatch/app.log}"
SINCE="${2:-}"

if [ ! -f "$LOG" ]; then
  echo "✗ no log at $LOG" >&2
  exit 2
fi

# The window. The app stamps ISO-8601 UTC, so the cutoff is built in the same
# shape and compared as a string — which sorts correctly for this format and
# needs no date parsing.
if [ -n "$SINCE" ]; then
  CUTOFF=$(date -u -r "$SINCE" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
else
  CUTOFF=$(date -u -v-120S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
fi

if [ -n "$CUTOFF" ]; then
  RECENT=$(awk -v c="$CUTOFF" '$1 >= c' "$LOG")
else
  RECENT=$(cat "$LOG")
fi

VERDICTS=$(printf '%s\n' "$RECENT" | grep -E "selftest .*: (PASS|FAIL|SKIP)|selftest-arm .*(PASS|FAIL)" || true)

if [ -z "$VERDICTS" ]; then
  # Silence is not success. A build whose self-tests never ran has proved
  # nothing, and saying so is the entire point of the gate.
  echo "✗ no self-test verdicts in the window (since ${CUTOFF:-beginning})" >&2
  echo "  The app may not have finished launching, or the drills did not run." >&2
  exit 3
fi

FAILED=$(printf '%s\n' "$VERDICTS" | grep -E "FAIL" || true)
SKIPPED=$(printf '%s\n' "$VERDICTS" | grep -E ": SKIP" || true)
PASSED=$(printf '%s\n' "$VERDICTS" | grep -cE "PASS" || true)

if [ -n "$SKIPPED" ]; then
  echo "→ self-tests skipped (not counted as passing):"
  printf '%s\n' "$SKIPPED" | sed 's/^/    /'
fi

if [ -n "$FAILED" ]; then
  echo "✗ self-test failures in the running build:" >&2
  printf '%s\n' "$FAILED" | sed 's/^/    /' >&2
  exit 1
fi

if [ "$PASSED" -eq 0 ]; then
  # A ✓ next to a zero is how a gate lies. Everything was skipped, so nothing
  # was proved — not a failure worth refusing a relaunch over, but never a tick.
  echo "→ no self-tests passed; every drill skipped"
  exit 0
fi

echo "✓ $PASSED self-test verdict(s) passed"
