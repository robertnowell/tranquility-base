#!/bin/bash
# Packaging acceptance for the side-by-side development identity. Builds both
# envelopes from this checkout, compares their code, and proves the production
# installer refuses to put Dev at the production path. Nothing is launched or
# installed.
set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/lib/paths.sh"

TMP=$(mktemp -d)
LANE_KEYCHAIN=""
ORIGINAL_USER_KEYCHAINS=()
cleanup() {
  if [ -n "$LANE_KEYCHAIN" ]; then
    if [ "${#ORIGINAL_USER_KEYCHAINS[@]}" -gt 0 ]; then
      security list-keychains -d user -s "${ORIGINAL_USER_KEYCHAINS[@]}" >/dev/null
    fi
    security delete-keychain "$LANE_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# Hosted runners have no unlocked personal signing identity. Falling through to
# bundle.sh's normal create-once path targets the locked login keychain and can
# wait forever for a dialog nobody can answer. Use a disposable, unlocked
# keychain there: the test still proves a certificate-backed designated
# requirement, without depending on or modifying a persistent identity.
if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
  while IFS= read -r keychain; do
    [ -z "$keychain" ] || ORIGINAL_USER_KEYCHAINS+=("$keychain")
  done < <(security list-keychains -d user \
    | sed -E 's/^[[:space:]]*"//; s/"$//')

  LANE_KEYCHAIN="$TMP/lane-signing.keychain-db"
  LANE_PASSWORD="lane-test-$PPID-$$"
  LANE_IDENTITY_NAME="Tranquility Lane Test $$"
  security create-keychain -p "$LANE_PASSWORD" "$LANE_KEYCHAIN"
  security set-keychain-settings -lut 3600 "$LANE_KEYCHAIN"
  security unlock-keychain -p "$LANE_PASSWORD" "$LANE_KEYCHAIN"
  security list-keychains -d user -s "$LANE_KEYCHAIN"
  VD_SIGN_CN="$LANE_IDENTITY_NAME" VD_SIGN_KEYCHAIN="$LANE_KEYCHAIN" \
    scripts/make-signing-identity.sh > "$TMP/signing.log"
  security set-key-partition-list -S apple-tool:,apple: -s \
    -k "$LANE_PASSWORD" "$LANE_KEYCHAIN" >/dev/null
  LANE_IDENTITY=$(security find-identity -p codesigning "$LANE_KEYCHAIN" \
    | sed -nE 's/^ *[0-9]+\) ([0-9A-F]+) .*/\1/p')
  [ -n "$LANE_IDENTITY" ] \
    || { echo "✗ disposable signing identity was not created" >&2; exit 1; }
  export VOICE_DISPATCH_SIGN_IDENTITY="$LANE_IDENTITY"
fi

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
