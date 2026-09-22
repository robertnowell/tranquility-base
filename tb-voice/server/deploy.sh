#!/bin/bash
# Deploy the manager, stamped with the commit it was built from (hf-15).
#
#   ./deploy.sh                 # deploy tranquility-manager from this tree
#   ./deploy.sh my-drill-agent  # same image, another name (a drill; see drills/isolation)
#
# It refuses a dirty tree, because a stamp that says 3b34309 when the image
# holds uncommitted edits is worse than no stamp at all.
set -euo pipefail
cd "$(dirname "$0")"

AGENT="${1:-tranquility-manager}"
PCC="${PIPECAT_BIN:-$HOME/.local/bin/pipecat}"

if [ -n "$(git status --porcelain -- . 2>/dev/null)" ]; then
  echo "✗ tb-voice/server is dirty — commit first, or the stamp lies." >&2
  git status --short -- . >&2
  exit 1
fi

SHA="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > build_stamped.py <<EOF
# Written by deploy.sh at build time. Not committed; see build_stamp.py.
STAMP = {"sha": "$SHA", "branch": "$BRANCH", "built_at": "$BUILT", "where": "deployed"}
EOF
trap 'rm -f build_stamped.py' EXIT

echo "→ deploying $AGENT from $SHA ($BRANCH)"
"$PCC" cloud deploy "$AGENT" --build-dir . --dockerfile Dockerfile --yes
echo "✓ $AGENT now runs $SHA; it says so in its first log line and in the ready event"
