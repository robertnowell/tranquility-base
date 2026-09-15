#!/bin/bash
# Local landing preparation: freshness guards, the shared source audit, and
# informational checks that require this Mac's authenticated harnesses/hooks.
# CI calls audit-source.sh directly on its assigned immutable candidate.
# Usage: scripts/preflight.sh [base] (default: origin/main)
set -euo pipefail
cd "$(dirname "$0")/.."

BASE_REF="${1:-origin/main}"
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
BASE=$(git rev-parse --verify "$BASE_REF^{commit}")

AHEAD=$(git rev-list --count "$BASE..HEAD")
BEHIND=$(git rev-list --count "HEAD..$BASE")
echo "→ $BRANCH is $AHEAD ahead, $BEHIND behind $BASE_REF ($BASE)"

if [ "$BEHIND" -gt 0 ]; then
  echo "✗ behind $BASE_REF by $BEHIND commit(s) — rebase or merge before landing:" >&2
  git log --oneline "HEAD..$BASE" | sed 's/^/    /' >&2
  echo "    git merge $BASE_REF        # or: git rebase $BASE_REF" >&2
  exit 1
fi

if [ "$AHEAD" -eq 0 ]; then
  echo "✓ nothing to land — $BRANCH is already $BASE_REF"
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

CANDIDATE=$(git rev-parse HEAD)
scripts/audit-source.sh "$CANDIDATE"

# test-dispatch-live-tui.sh is the one that closes the gap the eight repairs
# between 19 and 26 Aug all fell through: the source audit's tmux drill is nine good tests
# against a plain SHELL, which has no prompt glyph, so the composer reader is
# never exercised by it at all. Every one of those eight was found by a human
# losing a message. This one runs the real harness.
#
# Informational, not a hard gate, for the same reason the Codex drill is: it
# needs a logged-in `claude` and it creates a session on the app's own tmux
# server, so it can be affected by what else is running. It is loud when it
# fails and that is what it is for.
echo "→ live TUI dispatch drill (informational — needs a logged-in claude)"
if [ "${TB_SKIP_LIVE_HARNESS_DRILLS:-0}" = "1" ]; then
  echo "→ skipped by TB_SKIP_LIVE_HARNESS_DRILLS"
elif scripts/test-dispatch-live-tui.sh; then
  echo "✓ live TUI dispatch drill passed"
else
  echo "⚠ live TUI dispatch drill failed — read it before landing composer changes"
fi

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
if [ "${TB_SKIP_LIVE_HARNESS_DRILLS:-0}" = "1" ]; then
  echo "→ skipped by TB_SKIP_LIVE_HARNESS_DRILLS"
elif scripts/test-codex-lifecycle.sh; then
  echo "✓ codex lifecycle drill passed"
else
  echo "⚠ codex lifecycle drill failed — not blocking (see preflight.sh's own comment on why)" >&2
fi

# The hooks this Mac actually executes live in the main checkout's WORKING TREE,
# which any session can move. On 01 Sep it sat on a feature branch 887 commits
# behind, so every hook firing for both harnesses was a three-day-old file.
# Nothing failed. A stale hook does what it used to do, which is the quietest
# failure this repo has. Informational, not blocking: the tree belongs to
# whoever is deploying, and refusing to land a Swift change over it would be
# the wrong lever.
echo "→ live hooks"
if scripts/check-live-hooks.sh; then
  echo "✓ the hooks on disk are the hooks that shipped"
else
  echo "⚠ the hooks this machine runs are not origin/main (see above) - not blocking" >&2
fi

cat <<EOF

Preflight passed. Nothing has been pushed or deployed.

Open or update a pull request against main; required checks still apply:
  gh pr create --base main --head "$BRANCH"

Observe the completed merge before reporting "merged". A queued request is
not a completed merge, and a merge is not proof of the running app. Follow
CLAUDE.md for deployment ownership and runtime verification.
EOF
