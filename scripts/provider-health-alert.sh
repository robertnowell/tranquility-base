#!/bin/bash
# Run the provider probes and tell Slack when the answer CHANGES.
#
# Modelled on capture-health-alert.sh, and for the same reason: a check that
# posts every run is a check nobody reads. This posts when a provider stops
# serving and again when it comes back, because "it is fixed" is the half of
# the story the 4 Sep outage never got to tell — it ran for three and a half
# days and the recovery was equally silent.
set -uo pipefail
cd "$(dirname "$0")/.."
# --dry-run prints what it would post; --test-post proves delivery on install.
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
CHANNEL="C0BR963MBJ9"          # #alerts-tranquility-base
SECRETS="$HOME/.claude/plugins/cache/claude-secrets-marketplace/claude-secrets/1.0.0/bin/claude-secrets"
STATE="$HOME/Library/Application Support/VoiceDispatch/provider-health.state"
LEDGER="$(pwd)/logs/provider-health.log"

post() {
  local text
  text=$(cat)
  if [ "$DRY" = "1" ]; then echo "WOULD POST >>>"; printf '%s
' "$text"; return 0; fi
  TEXT="$text" CHANNEL="$CHANNEL" "$SECRETS" run --inject SLACK_WRITE_TOKEN=TOK -- \
    bash -c 'python3 -c "
import json,os,urllib.request
payload = json.dumps({\"channel\": os.environ[\"CHANNEL\"], \"text\": os.environ[\"TEXT\"]}).encode()
req = urllib.request.Request(\"https://slack.com/api/chat.postMessage\", data=payload,
    headers={\"Authorization\": \"Bearer \" + os.environ[\"TOK\"],
             \"Content-type\": \"application/json; charset=utf-8\"})
print(json.load(urllib.request.urlopen(req)).get(\"ok\"))
"' >/dev/null 2>&1
}

# The keys never touch this script's environment except inside the probe.
REPORT=$("$SECRETS" run \
  --inject ASSEMBLYAI_API_KEY=ASSEMBLYAI_API_KEY \
  --inject OPENAI_API_KEY=OPENAI_API_KEY \
  --inject ELEVENLABS_API_KEY=ELEVENLABS_API_KEY \
  -- python3 ./scripts/provider-health.py 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("stdout",""), end="")')

# Which providers are unhappy, as a stable one-line signature.
FAILING=$(printf '%s' "$REPORT" | sed -n 's/^[x?] \([a-z-]*\):.*/\1/p' | sort | tr '\n' ',' )
FAILING=${FAILING:-none}
PREV="none"
[ -f "$STATE" ] && PREV=$(cat "$STATE")

mkdir -p "$(dirname "$LEDGER")" "$(dirname "$STATE")"
printf '%s  failing=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FAILING" >> "$LEDGER"

if [ "$FAILING" != "$PREV" ]; then
  if [ "$FAILING" = "none" ]; then
    {
      echo ":white_check_mark: *Providers are serving again* (was: ${PREV%,})"
      echo '```'
      printf '%s\n' "$REPORT"
      echo '```'
    } | post
  else
    {
      echo ":credit_card: *A provider stopped serving:* ${FAILING%,}"
      echo "A valid key is not a serving key. These probes open the exact connection the app opens."
      echo '```'
      printf '%s\n' "$REPORT"
      echo '```'
    } | post
  fi
fi
[ "$DRY" = "1" ] || printf '%s' "$FAILING" > "$STATE"

[ "$FAILING" = "none" ] || exit 1
