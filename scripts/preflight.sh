#!/bin/bash
#
# Everything that must be true before a branch lands, and nothing that lands it.
#
# Why this stops short of pushing: this repo has no CI, and the layer that
# collides most — Sources/TranquilityApp — has no unit tests at all, so a green
# `swift test` is not evidence about the panel. A one-command land-and-deploy
# would put the frictionless path exactly where the judgment is needed. So this
# does the mechanical part and then prints the command it deliberately did not
# run.
#
# It also closes the failure that actually happened (08 Aug): local `main` sat
# two unpushed commits away from origin/main for a day while origin/main moved
# on. Nobody noticed until a merge went looking. Checking is cheap; discovering
# it mid-merge is not.
#
# Usage: scripts/preflight.sh [base]        (default base: origin/main)
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${1:-origin/main}"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [ "$BRANCH" = "HEAD" ]; then
  echo "✗ detached HEAD — check out the branch you mean to land." >&2
  exit 1
fi

# A dirty tree is not necessarily YOURS. Several sessions work this repo at once
# and one of them was mid-edit in these files as recently as this afternoon, so
# this refuses rather than stashing, and says whose problem it might be.
if [ -n "$(git status --porcelain)" ]; then
  echo "✗ working tree is dirty — refusing." >&2
  git status --short >&2
  echo "  If these edits are not yours, another session is live in this tree." >&2
  echo "  Commit or stash deliberately; never 'git add -A'." >&2
  exit 1
fi

echo "→ fetching"
git fetch -q origin

AHEAD=$(git rev-list --count "$BASE..HEAD")
BEHIND=$(git rev-list --count "HEAD..$BASE")
echo "→ $BRANCH is $AHEAD ahead, $BEHIND behind $BASE"

if [ "$BEHIND" -gt 0 ]; then
  echo "✗ behind $BASE by $BEHIND commit(s) — rebase or merge before landing:" >&2
  git log --oneline "HEAD..$BASE" | sed 's/^/    /' >&2
  echo "    git merge $BASE        # or: git rebase $BASE" >&2
  exit 1
fi

if [ "$AHEAD" -eq 0 ]; then
  echo "✓ nothing to land — $BRANCH is already $BASE"
  exit 0
fi

# Local main drifting from origin/main is the specific bug this catches.
if git show-ref -q --verify refs/heads/main; then
  MAIN_AHEAD=$(git rev-list --count "origin/main..main")
  if [ "$MAIN_AHEAD" -gt 0 ]; then
    echo "✗ local main has $MAIN_AHEAD commit(s) not on origin/main:" >&2
    git log --oneline origin/main..main | sed 's/^/    /' >&2
    echo "  Resolve that before landing, or this merge will fork it further." >&2
    exit 1
  fi
fi

echo "→ building"
swift build 2>&1 | grep -E "error:|warning: .*never used" || true
swift build >/dev/null

echo "→ testing"
# Captured, never piped. `... | grep -q ...` under `set -o pipefail` reports a
# FAILED pipeline on success: grep exits the moment it matches, the writer takes
# SIGPIPE, and pipefail faithfully reports that non-zero. It cost one false
# "tests failed" on a green tree — a check that cries wolf gets deleted, so it
# is worth the extra variable.
#
# That was fixed HALF WAY the first time: the run was captured into a variable,
# and then the variable was piped into `grep -q` anyway, which is the same race
# one line further down. It reappeared on 09 Aug the moment the suite grew — the
# first "with 0 failures" sits near the top of 68KB of output, so grep matched
# and exited while printf still had most of it to write, and preflight reported
# "tests failed (exit 0)" on a tree where all 277 passed. Under `bash -x` it
# passed, which is the signature of a race and cost a while to see.
#
# So: no pipe at all. Bash can test a substring without spawning anything, and
# a check with no subprocess has no pipeline to fail.
#
# Two invocations, not one — found 24 Aug on a new machine (App-lane P9): a
# bare `swift test` here silently runs ONLY the Swift Testing suites and
# skips every XCTestCase-based test with no error, no non-zero exit, nothing
# — 31 tests reported as green while 881 XCTestCase tests never ran. Passing
# `--enable-xctest --disable-swift-testing` is what actually forces the
# XCTest bundle to run; the default/both-enabled invocation reliably drops
# it on this toolchain. `arch -arm64e` because plain `swift`/`swift test`
# resolve to the x86_64 slice in this shell, which cannot dlopen the
# arm64e-only XCTest bundle at all. Both frameworks are checked separately
# so a silent zero in either one is a hard failure, not a quiet pass.
#
# The exit STATUS is the verdict; the summary line is a corroborating check that
# the run actually happened rather than dying before it reached the tests.
# Through scripts/test.sh, which runs both invocations AND refuses to report
# success unless each half cleared a floor. The two-invocation mechanism below
# was this file's, found at App-lane P9; the floor is what stops an
# "Executed 0 tests, with 0 failures" from reading as green.
TEST_OUT=$(scripts/test.sh 2>&1) && TEST_STATUS=0 || TEST_STATUS=$?
if [ "$TEST_STATUS" -ne 0 ]; then
  echo "✗ tests failed (exit $TEST_STATUS)" >&2
  printf '%s\n' "$TEST_OUT" | grep -E "✗|error:|XCTAssert" | head -20 >&2 || true
  exit 1
fi
printf '%s\n' "$TEST_OUT" | grep -E "^✓ [0-9]+ XCTest" | tail -1 | sed 's/^✓/ /'
echo "✓ build clean, tests green"

# --- the drills that were never actually wired to anything --------------------
#
# Found in the arc's closing audit (24 Aug): the arc's own rule 4 requires
# "the drills" — swift test, scripts/test-dispatch-tmux.sh, --selftest-hud —
# on every landing, but this file only ever ran the first. The other two were
# real, working, human-run-when-remembered scripts with no gate behind them:
# a regression in either could ship and nothing here would catch it before
# someone noticed by hand. Worse for Codex specifically — test-codex-
# lifecycle.sh is the ONLY thing in this repo that exercises a real Codex
# session end to end, and it wasn't run by this script even once.
#
# test-dispatch-tmux.sh is a hard gate: it drives its own tmux server on a
# dedicated socket (tbdrill-<pid>), so it stays correct whether or not a real
# Tranquility Base instance is running alongside it.
echo "→ tmux dispatch drill"
scripts/test-dispatch-tmux.sh

# test-codex-lifecycle.sh is NOT that isolated, discovered the hard way (24
# Aug, minutes after first wiring this in): it drives the real `tbase` CLI
# against the real, shared session-ownership.json and the real tmux server —
# the same state a live Tranquility Base instance manages. With one running
# (the ordinary, expected state for this app — it's a menu-bar app people
# leave open all day), the drill's own attemptCodexResume raced the live
# app's session polling over the same Codex session and failed 4/6, twice,
# on a tree with zero Sources/ changes. Hard-gating on that would make
# preflight fail essentially at random depending on who else has the app
# open — worse than not running it, because a check that cries wolf gets
# disabled, not fixed. So: run it, report it, never block on it, until it
# gets the same self-contained isolation test-dispatch-tmux.sh already has.
echo "→ codex lifecycle drill (informational — see comment above)"
if scripts/test-codex-lifecycle.sh; then
  echo "✓ codex lifecycle drill passed"
else
  echo "⚠ codex lifecycle drill failed — not blocking (see preflight.sh's own comment on why)" >&2
fi

# --- the palette owns every colour --------------------------------------------
#
# StateLegend.swift already carries a grep contract in writing, for glyphs: the
# state characters are "defined here and nowhere else in this module". Colour
# earns the same rule, and earned it the hard way — CheckView's tick was a
# hardcoded near-white, correct against the old dark green and 1.88:1 against the
# new one. An invisible checkmark, in one state, discoverable only by hitting
# that state at runtime.
#
# The contrast drill cannot catch that class: it measures Palette tokens, and a
# literal pasted into a view is by definition not one. This is the check that
# sees it, and it costs nothing.
echo "→ colour literals"
STRAY=$(grep -rn 'NSColor(srgbRed:\|NSColor(calibratedRed:\|NSColor(red:' \
  Sources/ --include='*.swift' | grep -v 'Sources/TranquilityApp/StateLegend.swift:' || true)
if [ -n "$STRAY" ]; then
  echo "✗ colour literal outside the Palette:" >&2
  printf '%s\n' "$STRAY" >&2
  echo "  Add it to StateLegend.Palette and reference it from there — a literal" >&2
  echo "  in a view is a colour no drill can measure and no theme can move." >&2
  exit 1
fi
echo "✓ every colour comes from the Palette"

cat <<EOF

Preflight passed. Nothing has been pushed or deployed — deliberately.

  Remember what green does and does not mean here: swift test proves
  TranquilityCore. It says nothing about Sources/TranquilityApp, which has no
  unit tests. The panel's evidence is the launch self-tests, and those only
  speak after scripts/relaunch.sh.

To land:
  git branch -f main $BRANCH && git push origin main:main && scripts/relaunch.sh

  (branch -f rather than checkout: it moves the ref without touching a working
  tree another session may be editing.)
EOF
