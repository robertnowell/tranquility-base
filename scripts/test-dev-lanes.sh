#!/bin/bash
# Packaging acceptance for the side-by-side development identity. Builds both
# envelopes from this checkout, compares their code, and proves the production
# installer refuses to put Dev at the production path. Nothing is launched or
# installed.
set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/lib/paths.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

env -u MallocStackLogging TB_ARCHS="${TB_ARCHS:-arm64}" \
  scripts/bundle.sh debug > "$TMP/prod.log" 2>&1
env -u MallocStackLogging TB_ARCHS="${TB_ARCHS:-arm64}" \
  scripts/bundle-dev.sh debug > "$TMP/dev.log" 2>&1

PROD="$(tb_bundle_dir debug)/Tranquility Base.app"
DEV="$(tb_bundle_dir debug)/Tranquility Base Dev.app"
scripts/audit-dev.sh "$DEV" "$PROD"

set +e
INSTALL_OUTPUT=$(scripts/install.sh "$DEV" --no-login-item 2>&1)
INSTALL_STATUS=$?
set -e
[ "$INSTALL_STATUS" -ne 0 ] \
  || { echo "✗ production installer accepted the Dev bundle" >&2; exit 1; }
case "$INSTALL_OUTPUT" in
  *"Production requires com.robertnowell.voice-dispatch"*) ;;
  *) echo "✗ production installer refused Dev for the wrong reason" >&2; exit 1 ;;
esac

echo "✓ production installer cannot overwrite Prod with Dev"

# The original incident was subtler than putting Dev at the Prod path: a local
# build kept the production bundle id but carried an Apple Development signing
# requirement. Prove that exact shape is also refused before install.sh stops
# or replaces anything.
set +e
INSTALL_OUTPUT=$(scripts/install.sh "$PROD" --no-login-item 2>&1)
INSTALL_STATUS=$?
set -e
[ "$INSTALL_STATUS" -ne 0 ] \
  || { echo "✗ production installer accepted a local development signature" >&2; exit 1; }
case "$INSTALL_OUTPUT" in
  *"Prod accepts only the expected Developer ID release identity"*) ;;
  *) echo "✗ production installer refused local Prod for the wrong reason" >&2; exit 1 ;;
esac

echo "✓ production installer cannot recreate the signing collision"
echo "✓ Dev/Prod packaging acceptance passed"
