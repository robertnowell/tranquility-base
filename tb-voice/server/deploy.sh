#!/bin/bash
# Deploy the manager, stamped with the commit it was built from (hf-15).
#
#   ./deploy.sh                 # every production agent, from this tree
#   ./deploy.sh my-drill-agent  # same image, another name (a drill; see drills/isolation)
#   ./deploy.sh --even-if-live  # deploy over live sessions (they may be cut off)
#
# It refuses a dirty tree, because a stamp that says 3b34309 when the image
# holds uncommitted edits is worse than no stamp at all.
#
# Production is two agents, one per transport, and a plain run deploys both.
# On 23 Sep the app had moved to WebRTC (tranquility-manager-rtc) while every
# deploy went to tranquility-manager alone: the agent Robert was actually
# talking to stayed on an unstamped build from before three fixes, and his Mac's
# wire v1 hello went to code that ignored it (hf-23).
set -euo pipefail
cd "$(dirname "$0")"

PCC="${PIPECAT_BIN:-$HOME/.local/bin/pipecat}"
# One agent, since the WebSocket transport went. `tranquility-manager` served
# it and served nothing else; its last session was 23 Sep and the bot can no
# longer answer a socket at all, so deploying it would ship something that
# cannot run. Delete the agent itself once the Gateway is confirmed off it.
PRODUCTION=(tranquility-manager-rtc)

config_for() {
  case "$1" in
    tranquility-manager-rtc) echo "pcc-deploy-rtc.toml" ;;
    *) echo "pcc-deploy.toml" ;;
  esac
}

is_production() {
  local a
  for a in "${PRODUCTION[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

EVEN_IF_LIVE=0
NAMED=()
for arg in "$@"; do
  case "$arg" in
    --even-if-live) EVEN_IF_LIVE=1 ;;
    -*) echo "✗ unknown option $arg" >&2; exit 2 ;;
    *) NAMED+=("$arg") ;;
  esac
done
if [ ${#NAMED[@]} -gt 0 ]; then AGENTS=("${NAMED[@]}"); else AGENTS=("${PRODUCTION[@]}"); fi

# How many sessions an agent is serving right now, read from the one field of
# `pipecat cloud agent status` that says so. The CLI has no structured output,
# so this is parsed strictly at this boundary and fails closed: a count that
# cannot be read is treated as live (hf-28).
live_sessions() {
  "$PCC" cloud agent status "$1" 2>/dev/null \
    | sed -n 's/^Active Session Count: *\([0-9][0-9]*\) *$/\1/p' | head -1
}

if [ -n "$(git status --porcelain -- . 2>/dev/null)" ]; then
  echo "✗ tb-voice/server is dirty: commit first, or the stamp lies." >&2
  git status --short -- . >&2
  exit 1
fi

# Production takes only merged code: #572 went live by hand from a feature
# worktree on 22 Sep, and nothing stopped an unmerged commit going the same way.
# A drill agent may deploy anything; it is nobody's session (hf-23).
for AGENT in "${AGENTS[@]}"; do
  if is_production "$AGENT"; then
    git fetch -q origin
    if ! git merge-base --is-ancestor HEAD origin/main; then
      echo "✗ $(git rev-parse --short HEAD) is not on origin/main; only merged code goes to $AGENT" >&2
      exit 1
    fi
  fi
done

# A deploy restarts the agent's processes and can cut a live conversation off.
# On 24 Sep one ran with "Active Session Count: 1" printed a line above it,
# because the check and the deploy were chained and nothing read the count.
if [ "$EVEN_IF_LIVE" = 0 ]; then
  for AGENT in "${AGENTS[@]}"; do
    is_production "$AGENT" || continue
    n="$(live_sessions "$AGENT")"
    if [ -z "$n" ]; then
      echo "✗ could not read $AGENT's live sessions; not deploying over what may be a conversation (--even-if-live to override)" >&2
      exit 1
    fi
    if [ "$n" -gt 0 ]; then
      echo "✗ $AGENT has $n live session(s); not deploying over them (--even-if-live to override)" >&2
      exit 1
    fi
  done
fi

SHA="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > build_stamped.py <<EOF
# Written by deploy.sh at build time. Not committed; see build_stamp.py.
STAMP = {"sha": "$SHA", "branch": "$BRANCH", "built_at": "$BUILT", "where": "deployed"}
EOF
trap 'rm -f build_stamped.py' EXIT

for AGENT in "${AGENTS[@]}"; do
  CONFIG="$(config_for "$AGENT")"
  echo "→ deploying $AGENT from $SHA ($BRANCH, $CONFIG)"
  "$PCC" cloud deploy "$AGENT" --build-dir . --dockerfile Dockerfile --config-file "$CONFIG" --yes
  echo "✓ $AGENT now runs $SHA; it says so in its first log line and in the ready event"
done
