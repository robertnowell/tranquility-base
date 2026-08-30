#!/bin/bash
#
# Import short-lived GitHub Actions signing credentials, then run the ordinary
# release path. The runner is ephemeral, but cleanup is still explicit so a
# locally simulated run cannot leave a signing keychain behind.
#
# Required environment variables:
#   TB_DEVELOPER_ID_P12_BASE64
#   TB_DEVELOPER_ID_P12_PASSWORD
#   TB_NOTARY_APPLE_ID
#   TB_NOTARY_APP_PASSWORD
#
# Usage: scripts/ci-release.sh

set -euo pipefail
cd "$(dirname "$0")/.."

required=(
  TB_DEVELOPER_ID_P12_BASE64
  TB_DEVELOPER_ID_P12_PASSWORD
  TB_NOTARY_APPLE_ID
  TB_NOTARY_APP_PASSWORD
)
for name in "${required[@]}"; do
  [ -n "${!name:-}" ] || { echo "✗ required release secret is empty: $name" >&2; exit 1; }
done

RUNNER_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
CREDENTIAL_DIR=$(mktemp -d "$RUNNER_TEMP/tranquility-release.XXXXXX")
KEYCHAIN="$CREDENTIAL_DIR/signing.keychain-db"
P12="$CREDENTIAL_DIR/developer-id.p12"
KEYCHAIN_PASSWORD=$(uuidgen | tr -d -)
PROFILE="TB_CI_NOTARY"
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
  # security indents and quotes every path. Preserve paths containing spaces,
  # but remove only that presentation whitespace and the surrounding quotes.
  keychain=$(printf '%s\n' "$keychain" \
    | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')
  [ -z "$keychain" ] || ORIGINAL_KEYCHAINS+=("$keychain")
done < <(security list-keychains -d user)

cleanup() {
  if [ "${#ORIGINAL_KEYCHAINS[@]}" -gt 0 ]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  fi
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -f "$P12"
  rmdir "$CREDENTIAL_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
cleanup

printf '%s' "$TB_DEVELOPER_ID_P12_BASE64" | base64 --decode > "$P12"
chmod 600 "$P12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$TB_DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s \
  -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN"

EXPECTED_IDENTITY="Developer ID Application: Robert Nowell (FKE587SZ6H)"
IDENTITY_COUNT=$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | grep -F -c "\"$EXPECTED_IDENTITY\"" || true)
[ "$IDENTITY_COUNT" -eq 1 ] || {
  echo "✗ imported P12 must contain exactly one $EXPECTED_IDENTITY identity" >&2
  exit 1
}

xcrun notarytool store-credentials "$PROFILE" \
  --apple-id "$TB_NOTARY_APPLE_ID" \
  --team-id FKE587SZ6H \
  --password "$TB_NOTARY_APP_PASSWORD" \
  --keychain "$KEYCHAIN" >/dev/null

# The imported key and notary profile are all the release path needs. Remove
# the raw values from the environment before any repository build/audit code
# runs so child processes cannot inherit the original secrets accidentally.
unset TB_DEVELOPER_ID_P12_BASE64 TB_DEVELOPER_ID_P12_PASSWORD
unset TB_NOTARY_APPLE_ID TB_NOTARY_APP_PASSWORD

export TB_NOTARY_PROFILE="$PROFILE"
export TB_NOTARY_KEYCHAIN="$KEYCHAIN"
scripts/release.sh
