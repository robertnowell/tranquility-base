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
  # Prune first. /private/tmp is reaped — install.sh's own header names this as a
  # routine occurrence — and the reaper takes the directory while leaving git's
  # registration behind. `worktree add` then refuses:
  #
  #   fatal: '/private/tmp/tb-clean' is a missing but already registered worktree
  #
  # which broke the ONLY sanctioned relaunch path on 11 Aug, after a documented and
  # entirely expected event. Pruning is a no-op when nothing is stale, so it costs
  # nothing on the healthy path.
  git worktree prune
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
# Mirrors CaptureMarker.staleAfter, which this script cannot read because it is
# bash. The marker is re-stamped every CaptureMarker.heartbeat seconds for as
# long as the microphone is open, so age means "silence from the writer", not
# "length of the utterance". It was the second reading, at 180s, that let this
# script destroy a live four-minute capture on 10 Aug. Change both or neither.
STALE_AFTER=20
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

# Deploy INTO the installed copy when there is one.
#
# Once scripts/install.sh has run, /Applications holds the app the Dock,
# Spotlight and the login item all point at. Building here and opening the
# worktree copy instead would leave two bundles with one bundle id: the one you
# just built running now, and a stale one starting at your next login. So the
# built bundle replaces the installed one and everything downstream uses that
# path. No install, no change — the worktree copy stays the target, exactly as
# before, so this is safe on a machine that has never run the installer.
INSTALLED="/Applications/$APP"
if [ -d "$INSTALLED" ]; then
  echo "→ updating the installed copy"
  rm -rf "$INSTALLED"
  cp -R "$APP_PATH" "$INSTALLED"
  xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
  if ! codesign --verify --deep --strict "$INSTALLED" 2>/dev/null; then
    # A copy that does not verify is a DIFFERENT app to macOS: every permission
    # would be re-prompted. Keep running the worktree build rather than install
    # something that would silently cost the user their grants.
    echo "✗ the installed copy does not verify — leaving it and using the worktree build" >&2
    INSTALLED=""
  fi
  [ -n "$INSTALLED" ] && APP_PATH="$INSTALLED"
fi

# Only now. Two instances racing for one global hotkey is its own bug, so the old
# one goes down immediately before the new one comes up, not before the build.
if pgrep -f TranquilityApp >/dev/null; then
  echo "→ stopping running instance"
  pkill -f TranquilityApp || true
  sleep 1
fi

echo "→ launching (with panel self-tests)"
LAUNCHED_AT=$(date +%s)
# --selftest-hud, every relaunch. The drills were opt-in, which meant the panel's
# only evidence ran exactly when someone remembered to ask for it — i.e. never in
# the loop that ships code. They run synchronously at startup, paint through
# every state with worst-case text, and clean up onto the idle grid, which is
# where launch lands anyway. One instance, so no hotkey race.
#
# --selftest-arm is deliberately NOT included: it needs the microphone and drives
# the real recorder and store. Opt in by hand when changing the arm path.
open "$APP_PATH" --args --selftest-hud
sleep 4

if pgrep -f TranquilityApp >/dev/null; then
  echo "✓ running $TARGET"
else
  echo "✗ did not stay up — check ~/Library/Application Support/VoiceDispatch/app.log" >&2
  exit 1
fi

# The self-tests, read rather than merely run.
#
# The panel is the most-edited code in the repo and the only layer `swift test`
# cannot reach, so "252 tests green" has never said anything about it. The drills
# that CAN speak for it have run at every launch since the beginning and nothing
# ever looked at the answer. Now the relaunch does.
#
# Reporting, not refusing. The app is already up on the new build by this point,
# and taking it back down over a failed drill would contradict the one rule this
# script exists to hold — never leave the app down. A loud non-zero exit is
# enough to stop a merge; the operator decides what to do about the app.
#
# The drills are asynchronous (one reports five seconds after the undo window),
# so give them room before reading.
sleep 6
if ! ./scripts/check-selftests.sh "" "$LAUNCHED_AT"; then
  echo "✗ the build is running, but its self-tests did not pass." >&2
  echo "  Fix or revert before landing this — the panel has no other coverage." >&2
  exit 1
fi
