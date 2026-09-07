#!/usr/bin/env bash
#
# Publish diagnostics.json beside the update feed, the same way the appcast
# is published: one `gh api` PUT to the Pages branch, no credential plumbing.
#
# The app fetches https://updates.tranquilitybase.to/diagnostics.json at
# launch (off-main, cached) and starts its error reporting only when the DSN
# in it is non-empty. So this file is the switch for every install at once:
# rotate the DSN here, or empty it, and no build has to ship.
#
# Usage: scripts/publish-diagnostics.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="robertnowell/tranquility-base"
FEED_BRANCH="gh-pages"
FILE="diagnostics.json"

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$FILE" \
  || { echo "✗ $FILE is not valid JSON" >&2; exit 1; }

CONTENT=$(base64 < "$FILE" | tr -d '\n')
EXISTING_SHA=$(gh api "repos/$REPO/contents/$FILE?ref=$FEED_BRANCH" --jq .sha 2>/dev/null || true)
args=(-X PUT "repos/$REPO/contents/$FILE"
  -f "message=Diagnostics config $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  -f "content=$CONTENT"
  -f "branch=$FEED_BRANCH")
[ -z "$EXISTING_SHA" ] || args+=(-f "sha=$EXISTING_SHA")
gh api "${args[@]}" >/dev/null || { echo "✗ could not publish $FILE to $FEED_BRANCH" >&2; exit 1; }
DSN_STATE=$(python3 -c 'import json;print("present" if json.load(open("diagnostics.json")).get("sentryDsn") else "empty")')
echo "✓ published $FILE to $FEED_BRANCH (DSN $DSN_STATE); Pages serves it within a minute"
