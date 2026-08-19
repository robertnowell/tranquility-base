#!/bin/bash
#
# Run the capture-health invariants and say so in Slack when they break.
#
# Why a wrapper and not just the checker in a cron line: an alert that fires
# every two hours for the same three dead presses is an alert nobody reads by
# lunchtime, and the first thing to go quiet in that arrangement is the person.
# So this remembers what it has already said (per day, in a state file) and
# speaks only about what is new.
#
# It also writes a line for EVERY run, alert or not. The whole 19 Aug episode
# was a defect that was fully recorded and never read; a monitor whose only
# output is silence has the same shape. logs/capture-health.log is the answer
# to "is this thing still running", and --heartbeat posts the week's numbers to
# Slack once a week so that question has an answer in the channel too.
#
# Usage: scripts/capture-health-alert.sh [--heartbeat]
set -uo pipefail
cd "$(dirname "$0")/.."

CHANNEL="C0BR963MBJ9"          # #alerts-tranquility-base
SECRETS="$HOME/.claude/plugins/cache/claude-secrets-marketplace/claude-secrets/1.0.0/bin/claude-secrets"
STATE="$HOME/Library/Application Support/VoiceDispatch/capture-health.state"
LEDGER="$(pwd)/logs/capture-health.log"
TODAY=$(date +%Y-%m-%d)
WEEK_AGO=$(date -v-7d +%Y-%m-%d)
HEARTBEAT=0
[ "${1:-}" = "--heartbeat" ] && HEARTBEAT=1

# Slack takes the message on stdin so a report full of quotes, backticks and
# newlines survives the trip verbatim -- building JSON in bash by hand is how
# an alert becomes a 500-character escape bug at 3am.
post() {
  local text
  text=$(cat)
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

REPORT=$(./scripts/capture-health.py --since "$TODAY" 2>&1)
STATUS=$?

# The two counts, read from the verdict lines the checker already prints.
DEAD=$(printf '%s' "$REPORT" | sed -n 's/^x \([0-9]*\) dead press.*/\1/p')
UNROUTED=$(printf '%s' "$REPORT" | sed -n 's/^x \([0-9]*\) launch(es) registered.*/\1/p')
DEAD=${DEAD:-0}
UNROUTED=${UNROUTED:-0}

# What today has already been alerted about. A new day starts from zero: the
# rate is a daily fact, and yesterday's three do not silence today's first.
PREV_DAY=""; PREV_DEAD=0; PREV_UNROUTED=0
if [ -f "$STATE" ]; then
  read -r PREV_DAY PREV_DEAD PREV_UNROUTED < "$STATE" || true
fi
if [ "$PREV_DAY" != "$TODAY" ]; then PREV_DEAD=0; PREV_UNROUTED=0; fi

mkdir -p "$(dirname "$LEDGER")"
printf '%s  dead=%s unrouted=%s status=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DEAD" "$UNROUTED" "$STATUS" >> "$LEDGER"

if [ "$DEAD" -gt "$PREV_DEAD" ] || [ "$UNROUTED" -gt "$PREV_UNROUTED" ]; then
  {
    echo ":rotating_light: *Tranquility Base — capture health*"
    echo "New since the last alert: $((DEAD - PREV_DEAD)) dead press(es), $((UNROUTED - PREV_UNROUTED)) unrouted launch(es)."
    echo ""
    echo '```'
    printf '%s\n' "$REPORT"
    echo '```'
    echo "A dead press means a microphone open that never reached the hardware."
    echo "An unrouted launch means a + NEW AGENT registered and never said where the reply went — the 19 Aug misroute."
    echo "Run it yourself: \`scripts/capture-health.py --since $TODAY\`"
  } | post
  printf '%s %s %s\n' "$TODAY" "$DEAD" "$UNROUTED" > "$STATE"
  exit 1
fi

printf '%s %s %s\n' "$TODAY" "$DEAD" "$UNROUTED" > "$STATE"

if [ "$HEARTBEAT" = "1" ]; then
  {
    echo ":green_circle: *Tranquility Base — capture health, last 7 days*"
    echo ""
    echo '```'
    ./scripts/capture-health.py --since "$WEEK_AGO" 2>&1
    echo '```'
  } | post
fi
exit 0
