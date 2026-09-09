#!/bin/bash
# A symbol bundle from another build is as useless as a missing one.
set -euo pipefail
APP="${1:?usage: check-debug-symbols.sh APP DSYM}"
DSYM="${2:?usage: check-debug-symbols.sh APP DSYM}"
[ -f "$APP/Contents/MacOS/TranquilityApp" ] || { echo "missing app executable" >&2; exit 1; }
[ -d "$DSYM" ] || { echo "missing release debug symbols: $DSYM" >&2; exit 1; }
APP_IDS=$(dwarfdump --uuid "$APP/Contents/MacOS/TranquilityApp" | awk '/^UUID:/{print $2, $3}' | sort)
DSYM_IDS=$(dwarfdump --uuid "$DSYM" | awk '/^UUID:/{print $2, $3}' | sort)
[ -n "$APP_IDS" ] && [ "$APP_IDS" = "$DSYM_IDS" ] || {
  echo "debug symbol UUIDs/architectures do not match the release executable" >&2
  exit 1
}
echo "✓ release debug symbols match every executable slice"
