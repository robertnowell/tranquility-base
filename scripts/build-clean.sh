#!/bin/bash
#
# Build committed HEAD in a clean worktree, and print where the bundle landed.
#
# This was inline in relaunch.sh, which meant install.sh could not do it — and
# install.sh is the script a new machine runs first. So a fresh clone hit:
#
#   ✗ no bundle at /private/tmp/tb-clean/.build/debug/Tranquility Base.app
#     Build one first: scripts/relaunch.sh (or scripts/bundle.sh debug)
#
# an installer that refuses to install and refers you to the relaunch script,
# which is the one carrying the pkill fault. The installer solved "the app must
# live somewhere durable" and then sourced the thing it installs from the one
# directory documented as NOT durable, and could not rebuild it. Same shape as
# the .gitignore that protected corpus.jsonl and not the files derived from it:
# the fix was applied at the destination and not at the origin.
#
# Extracted rather than copied. Two scripts needing the same build is exactly how
# the settings pose ended up maintained in two places and drifting.
#
# Usage: scripts/build-clean.sh [ref]        (default ref: origin/main)
#        Prints the built .app path on stdout. Progress goes to stderr, so
#        `APP=$(scripts/build-clean.sh)` is safe.
set -euo pipefail
cd "$(dirname "$0")/.."

REF="${1:-origin/main}"
CLEAN_WORKTREE="/private/tmp/tb-clean"
APP="Tranquility Base.app"
APP_PATH="$CLEAN_WORKTREE/.build/debug/$APP"

# /private/tmp is fine for a build CACHE — it is reaped, and everything here can
# be rebuilt. It was only ever wrong as the app's only home, which is what
# install.sh exists to fix. What must not happen is the reaper leaving this
# script unable to proceed, which is the state that broke the only sanctioned
# relaunch path on 11 Aug.
git fetch -q origin
TARGET=$(git rev-parse --short "$REF")
echo "→ target: $TARGET  $(git log -1 --format=%s "$REF")" >&2

if [ ! -d "$CLEAN_WORKTREE" ]; then
  # Prune first. The reaper takes the directory and leaves git's registration
  # behind, after which `worktree add` refuses:
  #
  #   fatal: '/private/tmp/tb-clean' is a missing but already registered worktree
  #
  # Pruning is a no-op when nothing is stale, so it costs nothing when healthy.
  git worktree prune
  echo "→ creating $CLEAN_WORKTREE" >&2
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

echo "→ building $TARGET" >&2
( cd "$CLEAN_WORKTREE" && ./scripts/bundle.sh debug >/dev/null )

if [ ! -d "$APP_PATH" ]; then
  echo "✗ build reported success but produced no bundle at $APP_PATH" >&2
  exit 1
fi

echo "$APP_PATH"
