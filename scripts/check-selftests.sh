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

read_window() {
  if [ -n "$CUTOFF" ]; then
    awk -v c="$CUTOFF" '$1 >= c' "$LOG"
  else
    cat "$LOG"
  fi
}

# Wait for the drills to go QUIET before reading a verdict out of them.
#
# Not a longer sleep. One drill reports five seconds after it opens its undo
# window, and in that gap the launch task's own grid paint is legitimately
# refused by a stage the drill still owns. Read mid-flight, that refusal is the
# last line after the last verdict, which is exactly the shape check 1 below
# treats as a panel stuck holding the stage — so a healthy build failed its
# deploy, reproducibly, on a machine busy enough to slip past the caller's
# fixed `sleep`.
#
# Quiescence rather than a named drill: waiting for "pendingSend.afterWindow"
# would work today and would have to be edited by whoever adds the next drill
# that reports late. Waiting until the verdict count stops moving needs no
# such knowledge. The ceiling is generous because the cost of waiting is a few
# seconds on a deploy and the cost of not waiting is a false failure that
# teaches the operator to ignore this script.
# Quiescence was the right idea and the wrong measure, and it failed on the one
# shape it was written to survive.
#
# A drill that reports FIVE seconds late is invisible to a THREE-second quiet
# threshold: the count stops moving the instant the synchronous slate ends, the
# loop calls that settled, and the deferred verdicts land after the gate has
# already read. It held only while some other drill happened to run after
# `pendingSend` and keep the count ticking until the late ones arrived. On
# 27 Aug the drill order changed, `pendingSend` became the last synchronous
# drill, and the gate started reading a slate seven verdicts short — with that
# drill's legitimate, transient stage-claim as the last line, which check 1
# below correctly reads as a panel holding the stage. A healthy build failed
# its deploy, and the restore trap then brought the app back up with no drills
# at all: a red line about the wrong thing, and no coverage behind it.
#
# The old comment here named its own successor: "waiting for
# `pendingSend.afterWindow` would work today and would have to be edited by
# whoever adds the next drill that reports late." A marker is that idea without
# the maintenance — the slate says when it is done, so nothing here has to know
# what is in it or how long it takes.
SLATE_COMPLETE="selftest: slate complete"
SETTLE_QUIET_SECONDS=3
SETTLE_CEILING_SECONDS=45
settle() {
  local waited=0 stable=0 last=-1 now
  while [ "$waited" -lt "$SETTLE_CEILING_SECONDS" ]; do
    # The fact, when the build is new enough to state it.
    if read_window | grep -qF "$SLATE_COMPLETE"; then return 0; fi
    # The guess, for a build that predates the marker. Kept so this script can
    # still gate an older ref (a rollback, a bisect) rather than hanging for
    # the full ceiling on every one.
    now=$(read_window | grep -cE "selftest .*: (PASS|FAIL|SKIP)" || true)
    if [ "$now" -eq "$last" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge "$SETTLE_QUIET_SECONDS" ] && [ "$waited" -ge 12 ] && return 0
    else
      stable=0
      last="$now"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 0
}
settle

RECENT=$(read_window)

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

# ---------------------------------------------------------------------------
# The drills passed. Is the app still usable?
#
# These two checks exist because the answer was NO, twice, under a green tick
# (08 Aug). selfTestPendingSend left its card on the stage; pendingSend refuses
# every transition asked of it; and so the app took keystrokes and answered none
# of them while this script printed "✓ 10 self-test verdict(s) passed". The
# drills were all telling the truth. Nobody was asking the other question.
#
# Every drill asserts its own facts. Neither of these does: they ask only whether
# the panel came out of the drills able to accept input, which is the property a
# user has and no verdict line covers. Any FUTURE drill that leaves the panel
# hostage fails the deploy here, without anyone remembering to add a check.

# 1. Refusals AFTER the last verdict. During the drills refusals are expected —
#    several of them assert that the legality table refuses things. After the
#    last verdict there is no drill left to be refusing anything, so a refusal
#    there means something is still holding the stage.
LAST_VERDICT_LINE=$(printf '%s\n' "$RECENT" | grep -nE "selftest .*: (PASS|FAIL|SKIP)" | tail -1 | cut -d: -f1)
if [ -n "$LAST_VERDICT_LINE" ]; then
  AFTER=$(printf '%s\n' "$RECENT" | tail -n "+$((LAST_VERDICT_LINE + 1))")
  STUCK=$(printf '%s\n' "$AFTER" | grep -E "state: REFUSED" || true)
  if [ -n "$STUCK" ]; then
    echo "✗ the panel is refusing transitions after the drills finished:" >&2
    printf '%s\n' "$STUCK" | sed 's/^/    /' >&2
    echo "  A drill left the stage claimed. The app is up but will not answer input." >&2
    exit 4
  fi
fi

# 2. The state it settled in. The stage-owning states (PanelState.ownsStage)
#    legally refuse repaints, which is right while a capture is genuinely live
#    and wrong as a resting state seconds after launch. Anything else is fine —
#    speaking and preparing are ordinary launch outcomes.
LAST_STATE=$(printf '%s\n' "$RECENT" | grep -oE "state: [a-zA-Z.]+ -> [a-zA-Z.]+" | tail -1 | awk '{print $4}')
case "${LAST_STATE:-}" in
  listening|transcribing|pendingSend|arming)
    echo "✗ the panel settled in '$LAST_STATE', which owns the stage and refuses input." >&2
    echo "  Expected idle/hidden/speaking after launch. Something did not clean up." >&2
    exit 4
    ;;
esac

echo "✓ $PASSED self-test verdict(s) passed; panel accepting input (${LAST_STATE:-no transitions})"
