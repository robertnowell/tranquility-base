#!/bin/bash
#
# Put the running app on the latest committed main, in one command.
#
# Why this exists: merging is not deploying. This app is built locally into a
# worktree that somebody has to rebuild by hand, so `main` can be correct for an
# hour while the thing in the menu bar is three merges behind — which is exactly
# how a microphone fix sat merged while the microphone kept failing (07 Aug).
# There is no pipeline to close that gap, so this is the pipeline.
#
# It is deliberately the ONLY relaunch path. CLAUDE.md rule 3 says relaunches
# build committed HEAD in a clean worktree; doing that by hand is four commands
# with two ways to get it subtly wrong (building a dirty tree, or building the
# right commit in the wrong worktree). Both have happened.
#
# Usage: scripts/relaunch.sh [ref]     (default: origin/main)

set -euo pipefail
cd "$(dirname "$0")/.."

REF="${1:-origin/main}"
CLEAN_WORKTREE="/private/tmp/tb-clean"
APP="Tranquility Base.app"

# Resolve against the remote, not the local branch: a session that has merged but
# not pulled would otherwise relaunch the commit it already had.
git fetch -q origin
TARGET=$(git rev-parse --short "$REF")
echo "→ target: $TARGET  $(git log -1 --format=%s "$REF")"

# The clean worktree may not exist yet (fresh clone), or may be the pre-rename
# /tmp/vd-clean from before 023f201. Either way, create what is missing rather
# than failing on it.
if [ ! -d "$CLEAN_WORKTREE" ]; then
  echo "→ creating $CLEAN_WORKTREE"
  git worktree add --detach "$CLEAN_WORKTREE" "$REF" >/dev/null
else
  git -C "$CLEAN_WORKTREE" fetch -q origin
  git -C "$CLEAN_WORKTREE" checkout -q --detach "$TARGET"
fi

# Rule 3 is a hard rule for a reason: a dirty-tree binary once shipped a
# half-built feature that silently killed all audio. Refuse rather than warn.
if [ -n "$(git -C "$CLEAN_WORKTREE" status --porcelain)" ]; then
  echo "✗ $CLEAN_WORKTREE is dirty — refusing to build. Inspect it first." >&2
  git -C "$CLEAN_WORKTREE" status --short >&2
  exit 1
fi

# Stop before building, not after: the old instance holds the microphone and the
# ⌃⌥ hotkey, and two instances racing for a global hotkey is its own bug.
if pgrep -f TranquilityApp >/dev/null; then
  echo "→ stopping running instance"
  pkill -f TranquilityApp || true
  sleep 1
fi

echo "→ building"
( cd "$CLEAN_WORKTREE" && ./scripts/bundle.sh debug >/dev/null )

echo "→ launching"
open "$CLEAN_WORKTREE/.build/debug/$APP"
sleep 4

if pgrep -f TranquilityApp >/dev/null; then
  echo "✓ running $TARGET"
else
  echo "✗ did not stay up — check ~/Library/Application Support/VoiceDispatch/app.log" >&2
  exit 1
fi
