#!/bin/bash
# Return success only when Apple's notarization log has no reported issues.

set -euo pipefail

LOG_PATH="${1:-}"
[ -f "$LOG_PATH" ] || exit 1

ISSUES_TYPE=$(/usr/bin/plutil -type issues "$LOG_PATH" 2>/dev/null) || exit 1
case "$ISSUES_TYPE" in
  "(any)")
    # plutil's type for a JSON null. Apple emits this for a clean submission.
    exit 0
    ;;
  array)
    ISSUES_JSON=$(/usr/bin/plutil -extract issues json -o - "$LOG_PATH" 2>/dev/null) \
      || exit 1
    [ "$ISSUES_JSON" = "[]" ]
    ;;
  *)
    exit 1
    ;;
esac
