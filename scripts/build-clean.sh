#!/bin/bash
#
# Build committed HEAD in a clean worktree, and print where the bundle landed.
#
# This was inline in relaunch.sh, which meant install.sh could not do it — and
# install.sh is the script a new machine runs first. So a fresh clone hit:
#
#   ✗ no bundle at /private/tmp/tb-clean/.build/bundle/debug/Tranquility Base.app
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
. "$(dirname "$0")/lib/paths.sh"

REF="${1:-origin/main}"
CLEAN_WORKTREE="/private/tmp/tb-clean"
APP="Tranquility Base.app"
APP_PATH="$(tb_bundle_dir debug "$CLEAN_WORKTREE")/$APP"

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
  # The reaper takes files out of an EXISTING worktree too, and it does not
  # stop at the tracked ones. Seen 17 Aug: /private/tmp/tb-clean survived as a
  # directory with its .build cache intact, its `.git` link gone, and half its
  # tracked files deleted — which failed the deploy twice over. First as
  # `fatal: not a git repository`, from the fetch below; then, once the link
  # was repaired by hand, as a dirty-tree refusal listing three hundred
  # deletions. The only sanctioned relaunch path was down until somebody
  # worked out that /tmp had eaten the worktree rather than that a session had
  # left it dirty, and the message said the opposite.
  #
  # Both halves self-heal here, because both are unambiguous damage: this
  # directory is a build cache nobody edits, so a broken link is never
  # somebody's work in progress, and DELETIONS ONLY are never an edit either.
  # Anything else — a modification, an untracked file — still refuses below,
  # which is the case rule 3 is actually about.
  if ! git -C "$CLEAN_WORKTREE" rev-parse --git-dir >/dev/null 2>&1; then
    echo "→ $CLEAN_WORKTREE lost its git link (the /tmp reaper) — repairing" >&2
    git worktree prune
    git worktree repair "$CLEAN_WORKTREE" >/dev/null 2>&1 || true
  fi
  if ! git -C "$CLEAN_WORKTREE" rev-parse --git-dir >/dev/null 2>&1; then
    echo "→ $CLEAN_WORKTREE is past repairing — rebuilding it from scratch" >&2
    rm -rf "$CLEAN_WORKTREE"
    git worktree prune
    git worktree add --detach "$CLEAN_WORKTREE" "$REF" >/dev/null
  fi
  # Restore before fetching: a reaped tree can be missing the scripts this
  # very run is about to call.
  if [ -n "$(git -C "$CLEAN_WORKTREE" status --porcelain)" ] \
     && [ -z "$(git -C "$CLEAN_WORKTREE" status --porcelain | grep -v '^ D ')" ]; then
    gone=$(git -C "$CLEAN_WORKTREE" status --porcelain | wc -l | tr -d ' ')
    echo "→ restoring $gone reaped file(s) in $CLEAN_WORKTREE" >&2
    git -C "$CLEAN_WORKTREE" checkout -- .
  fi
  # A FETCH THAT CANNOT HANG FOREVER.
  #
  # 03 Sep: this line hung for 43 minutes on `ssh` to github.com. relaunch.sh
  # holds a lockfile while it runs and refuses every other deploy, so one stalled
  # network call froze deploying on the whole machine — silently, because a
  # hanging fetch prints nothing. Two bounds, because either alone is not enough:
  # ssh gives up on a dead connection, and the whole fetch gives up on a live one
  # that has stopped making progress.
  #
  # A failed fetch is not fatal. The worktree still has whatever it fetched last,
  # and the checkout below either finds the target or fails loudly, which is the
  # outcome we want over waiting forever.
  if ! GIT_SSH_COMMAND="ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3" \
       git -C "$CLEAN_WORKTREE" \
           -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
           fetch -q origin; then
    echo "→ fetch failed or timed out; building from what the worktree already has" >&2
  fi
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
