#!/bin/bash
# Assert the identity envelope that keeps Dev beside an untouched Prod app.
# Optional second argument: a production bundle from the same source commit;
# its executable instructions are compared with Dev after removing signatures.
set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/lib/paths.sh"

DEV="${1:-/Applications/Tranquility Base Dev.app}"
PROD="${2:-}"
fail() { echo "✗ $*" >&2; exit 1; }
read_dev() { /usr/libexec/PlistBuddy -c "Print :$1" "$DEV/Contents/Info.plist" 2>/dev/null; }

[ -d "$DEV" ] || fail "no Dev bundle at $DEV"
[ "$(read_dev CFBundleDisplayName)" = "Tranquility Base Dev" ] || fail "wrong display name"
[ "$(read_dev CFBundleIdentifier)" = "com.robertnowell.voice-dispatch.dev" ] || fail "wrong bundle id"
[ "$(read_dev TBAppChannel)" = "development" ] || fail "wrong channel"
[ "$(read_dev TBUpdatesEnabled)" = "false" ] || fail "updates are enabled"
[ "$(read_dev SUEnableAutomaticChecks)" = "false" ] || fail "automatic checks are enabled"
[ "$(read_dev SUAutomaticallyUpdate)" = "false" ] || fail "automatic install is enabled"
[ "$(read_dev CFBundleURLTypes:0:CFBundleURLSchemes:0)" = "tranquilitybase" ] \
  || fail "durable tranquilitybase URL scheme is absent"
[ "$(read_dev CFBundleURLTypes:0:CFBundleURLSchemes:1)" = "voicedispatch" ] \
  || fail "durable voicedispatch URL scheme is absent"
[ "$(read_dev CFBundleURLTypes:0:CFBundleURLSchemes:2)" = "tbdev" ] \
  || fail "development-only tbdev URL scheme is absent"
if /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes:0:CFBundleURLSchemes:3" \
   "$DEV/Contents/Info.plist" >/dev/null 2>&1; then
  fail "Dev claims an unexpected fourth URL scheme"
fi
codesign --verify --deep --strict "$DEV" 2>/dev/null || fail "signature does not verify"
DEV_SIGNING=$(codesign -dv --verbose=2 "$DEV" 2>&1 || true)
case "$DEV_SIGNING" in
  *$'\nAuthority='*|Authority=*) ;;
  *) fail "ad-hoc signature would reset TCC on rebuild" ;;
esac
DEV_ENTITLEMENTS=$(codesign -d --entitlements :- "$DEV" 2>/dev/null || true)
case "$DEV_ENTITLEMENTS" in
  *com.apple.security.cs.disable-library-validation*)
    fail "temporary icon-helper entitlement leaked into the final app" ;;
esac

if [ -n "$PROD" ]; then
  [ -d "$PROD" ] || fail "no Prod comparison bundle at $PROD"
  PROD_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "$PROD/Contents/Info.plist" 2>/dev/null || echo "")
  [ "$PROD_ID" = "com.robertnowell.voice-dispatch" ] || fail "comparison is not Prod"
  DEV_COMMIT=$(read_dev TBSourceCommit)
  PROD_COMMIT=$(/usr/libexec/PlistBuddy -c "Print :TBSourceCommit" \
    "$PROD/Contents/Info.plist" 2>/dev/null || echo "")
  [ "$DEV_COMMIT" = "$PROD_COMMIT" ] || fail "source commits differ"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  cp "$DEV/Contents/MacOS/TranquilityApp" "$TMP/dev"
  cp "$PROD/Contents/MacOS/TranquilityApp" "$TMP/prod"
  codesign --remove-signature "$TMP/dev" >/dev/null 2>&1
  codesign --remove-signature "$TMP/prod" >/dev/null 2>&1
  otool -tvV "$TMP/dev" | tail -n +2 > "$TMP/dev.instructions"
  otool -tvV "$TMP/prod" | tail -n +2 > "$TMP/prod.instructions"
  cmp -s "$TMP/dev.instructions" "$TMP/prod.instructions" \
    || fail "executable instruction payloads differ"
  echo "✓ Dev and Prod carry the same executable instructions"
fi

echo "✓ Dev identity is isolated, stable, and cannot consume production updates"
