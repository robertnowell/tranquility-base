#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURES=$(mktemp -d "${TMPDIR:-/tmp}/tb-notary-log-test.XXXXXX")
trap 'rm -rf "$FIXTURES"' EXIT INT TERM

printf '%s\n' '{"status":"Accepted","issues":null}' >"$FIXTURES/null.json"
printf '%s\n' '{"status":"Accepted","issues":[]}' >"$FIXTURES/empty.json"
printf '%s\n' '{"status":"Accepted","issues":[{"severity":"warning"}]}' \
  >"$FIXTURES/nonempty.json"
printf '%s\n' '{"status":"Accepted"}' >"$FIXTURES/missing.json"
printf '%s\n' 'not-json' >"$FIXTURES/malformed.json"

scripts/notary-log-is-clean.sh "$FIXTURES/null.json"
scripts/notary-log-is-clean.sh "$FIXTURES/empty.json"
for rejected in nonempty missing malformed; do
  if scripts/notary-log-is-clean.sh "$FIXTURES/$rejected.json"; then
    echo "✗ notarization parser accepted $rejected issues" >&2
    exit 1
  fi
done

echo "✓ notarization parser accepts only null or empty issues"
