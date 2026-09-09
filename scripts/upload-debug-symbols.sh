#!/bin/bash
# Publishing depends on symbols being accepted by the error tracker.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?usage: upload-debug-symbols.sh APP DSYM}"
DSYM="${2:?usage: upload-debug-symbols.sh APP DSYM}"
scripts/check-debug-symbols.sh "$APP" "$DSYM"
command -v sentry-cli >/dev/null || { echo "release requires sentry-cli" >&2; exit 1; }
[ -n "${SENTRY_AUTH_TOKEN:-}" ] || { echo "release requires SENTRY_AUTH_TOKEN" >&2; exit 1; }
SENTRY_ORG=$(python3 -c 'import json; print(json.load(open("diagnostics.json")).get("org", ""))')
SENTRY_PROJECT=$(python3 -c 'import json; print(json.load(open("diagnostics.json")).get("project", ""))')
[ -n "$SENTRY_ORG" ] && [ -n "$SENTRY_PROJECT" ] || {
  echo "release requires a debug-symbol organization and project" >&2; exit 1;
}
sentry-cli debug-files upload --wait --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" "$DSYM"
