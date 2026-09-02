#!/bin/bash
# Do the hooks this machine ACTUALLY EXECUTES match the code we think shipped?
#
# Both harnesses point their hook configs at absolute paths inside the main
# checkout:
#
#   ~/.claude/settings.json  ->  <repo>/hooks/artifact-hook.sh
#   ~/.codex/hooks.json      ->  <repo>/hooks/artifact-hook.sh
#
# That is a WORKING TREE, and any session can move it. On 01 Sep it was parked
# on a feature branch 887 commits behind origin/main, which meant every hook
# firing on this Mac, for both harnesses, was a three-day-old file. Nothing
# failed and nothing warned: a stale hook does not error, it just quietly does
# what it used to do. Robert found it by asking why Codex pages had no footer,
# and the honest answer was that the fix existed and the machine had never seen
# it.
#
# So the question gets asked out loud, every preflight. Reports and exits 1 on
# drift; never modifies anything.

set -u
cd "$(dirname "$0")/.." || exit 0
REPO="$(pwd)"

# The checkout the hook configs name, which is the repo root, not this worktree.
MAIN="$(git rev-parse --git-common-dir 2>/dev/null | sed 's|/\.git$||')"
case "$MAIN" in
  /*) ;;
  *) MAIN="$REPO" ;;
esac

git -C "$MAIN" fetch -q origin 2>/dev/null || true

problems=0
say() { printf '%s\n' "$1"; }

# 1. Every hook path the two configs reference, deduped.
paths=$(
  { python3 - <<'PY' 2>/dev/null
import json, os
seen = []
for p in ("~/.claude/settings.json", "~/.codex/hooks.json"):
    p = os.path.expanduser(p)
    if not os.path.exists(p):
        continue
    try:
        d = json.load(open(p))
    except Exception:
        continue
    def walk(o):
        if isinstance(o, dict):
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
        elif isinstance(o, str) and o.endswith(".sh") and "/hooks/" in o:
            seen.append(o.split()[0])
    walk(d)
for s in sorted(set(seen)):
    print(s)
PY
  }
)

[ -z "$paths" ] && { say "  no hook scripts referenced by either config"; exit 0; }

while IFS= read -r hook; do
  [ -z "$hook" ] && continue
  name="${hook##*/}"
  if [ ! -f "$hook" ]; then
    say "  MISSING  $hook"
    say "           a config references a hook that is not on disk; it fails open and silently"
    problems=$((problems + 1))
    continue
  fi
  # Only repo-owned hooks can be compared against the ref.
  case "$hook" in
    "$MAIN"/hooks/*) ;;
    *) say "  external $name (not in this repo, not checked)"; continue;;
  esac
  if git -C "$MAIN" show "origin/main:hooks/$name" 2>/dev/null | diff -q - "$hook" >/dev/null 2>&1; then
    say "  ok       $name"
  else
    say "  DRIFTED  $name"
    say "           the executed file differs from origin/main:hooks/$name"
    problems=$((problems + 1))
  fi
done <<EOF
$paths
EOF

# 2. And the checkout itself, because a hook that matches today drifts the
#    moment somebody parks this tree on a branch.
branch=$(git -C "$MAIN" rev-parse --abbrev-ref HEAD 2>/dev/null)
behind=$(git -C "$MAIN" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
if [ "$branch" != "main" ]; then
  say "  DRIFTED  the hook checkout is on '$branch', not main"
  say "           rule 5: the main checkout is for reading and deploying, never for editing"
  problems=$((problems + 1))
elif [ "${behind:-0}" -gt 0 ]; then
  say "  DRIFTED  the hook checkout is $behind commit(s) behind origin/main"
  problems=$((problems + 1))
else
  say "  ok       checkout on main, current"
fi

if [ "$problems" -gt 0 ]; then
  say ""
  say "  $problems problem(s). Both harnesses run these files; a stale one does not"
  say "  fail, it does what it used to do. Fix with:"
  say "    git -C $MAIN checkout main && git -C $MAIN pull --ff-only"
  exit 1
fi
exit 0
