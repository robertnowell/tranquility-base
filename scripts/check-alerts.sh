#!/bin/bash
# Every NSAlert the app shows goes through Alerts (Sources/TranquilityApp/Alerts.swift),
# which records it as a Failure (so it reaches Slack) and withholds repeats.
# Ruled 19 Sep after five dialogs were found with no record and ten copies of
# one landed in fourteen minutes. A bare NSAlert() anywhere else is the class
# coming back.
set -euo pipefail
cd "$(dirname "$0")/.."
bad=$(grep -rn 'NSAlert()' Sources --include='*.swift' \
  | grep -v '^Sources/TranquilityApp/Alerts.swift:' \
  | grep -vE 'Alerts\.(runModal|beginSheet)' \
  | while IFS= read -r line; do
      f=${line%%:*}
      # The alert is built at one site and handed to Alerts a few lines on;
      # a file that constructs one must hand every one over.
      built=$(grep -c 'NSAlert()' "$f")
      handed=$(grep -cE 'Alerts\.(runModal|beginSheet)\(' "$f")
      [ "$built" -le "$handed" ] || echo "$line"
    done || true)
if [ -n "$bad" ]; then
  echo "NSAlert shown outside Alerts (record it and gate it through Alerts.runModal / Alerts.beginSheet):" >&2
  echo "$bad" >&2
  exit 1
fi
echo "check-alerts: every NSAlert goes through Alerts"
