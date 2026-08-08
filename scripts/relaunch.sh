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
APP_PATH="$CLEAN_WORKTREE/.build/debug/$APP"

# Never exit leaving the app down.
#
# There is a window between stopping the old instance and launching the new one,
# and anything that kills this script inside it leaves no menu bar item at all —
# with nothing on screen to say why. Observed for real while testing: piping the
# output through `head` closed the pipe, SIGPIPE'd the script just after pkill,
# and the app simply vanished.
#
# Being one build behind is recoverable. Being gone is the failure this whole
# script exists to prevent, so put back whatever is on disk before leaving.
restore_if_down() {
  if ! pgrep -f TranquilityApp >/dev/null 2>&1 && [ -d "$APP_PATH" ]; then
    echo "→ interrupted mid-relaunch; bringing the app back up" >&2
    open "$APP_PATH" 2>/dev/null || true
  fi
}
trap restore_if_down EXIT INT TERM PIPE

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

# Never kill a live microphone.
#
# The recorder holds the whole utterance in memory and flushes once at key-up, so
# killing mid-sentence does not lose a file — it loses the words. That was
# survivable while a person chose the moment to relaunch. It stopped being
# survivable when a merge started firing this automatically, possibly from a
# session the speaker is not watching.
#
# The marker is written by Recorder.start and cleared by stop/abandon; it carries
# its start time so a crash cannot wedge relaunches forever (see CaptureMarker).
MARKER="$HOME/Library/Application Support/VoiceDispatch/capturing"
STALE_AFTER=180
GIVE_UP_AFTER=120
waited=0
while [ -f "$MARKER" ]; do
  started=$(cat "$MARKER" 2>/dev/null || echo 0)
  case "$started" in ''|*[!0-9]*) started=0 ;; esac
  age=$(( $(date +%s) - started ))
  if [ "$started" -eq 0 ] || [ "$age" -ge "$STALE_AFTER" ]; then
    echo "→ ignoring a stale capture marker (${age}s old)"
    break
  fi
  if [ "$waited" -ge "$GIVE_UP_AFTER" ]; then
    # Refusing is the safe failure: the app keeps running its current build,
    # which is exactly what it was doing a second ago. Losing the utterance is
    # not recoverable; being one commit behind for another minute is.
    echo "✗ microphone still open after ${waited}s — not relaunching." >&2
    echo "  The app stays on its current build. Run this again when you're done." >&2
    exit 1
  fi
  [ "$waited" -eq 0 ] && echo "→ microphone is open; waiting for the utterance to finish"
  sleep 2
  waited=$(( waited + 2 ))
done

# BUILD FIRST, then stop, then launch.
#
# The old order stopped the app and then built, which left it down for the whole
# build — around forty seconds — and anything that killed this script in there
# left it down for good. The EXIT trap could not save it either, because
# bundle.sh `rm -rf`s the .app it is about to recreate, so for most of that
# window there was nothing on disk to reopen. Measured the hard way: a `| head`
# closed the pipe mid-build and the menu bar item simply went away.
#
# Building first inverts that. The app keeps running while the slow part happens
# and the window where it is down shrinks from the length of a build to the
# length of a launch. The cost is that bundle.sh replaces the bundle underneath a
# running process; that is safe here because this app loads nothing from its
# bundle after launch — it draws its whole interface programmatically — and the
# process is replaced seconds later anyway.
echo "→ building"
( cd "$CLEAN_WORKTREE" && ./scripts/bundle.sh debug >/dev/null )

# Only now. Two instances racing for one global hotkey is its own bug, so the old
# one goes down immediately before the new one comes up, not before the build.
if pgrep -f TranquilityApp >/dev/null; then
  echo "→ stopping running instance"
  pkill -f TranquilityApp || true
  sleep 1
fi

echo "→ launching"
open "$APP_PATH"
sleep 4

if pgrep -f TranquilityApp >/dev/null; then
  echo "✓ running $TARGET"
else
  echo "✗ did not stay up — check ~/Library/Application Support/VoiceDispatch/app.log" >&2
  exit 1
fi
