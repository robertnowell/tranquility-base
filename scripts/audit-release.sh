#!/bin/bash
#
# Audit the exact DMG that will be handed to a user.
#
# Source tests answer whether the code behaves. This answers the orthogonal
# release question: did the intended commit survive assembly, signing,
# notarization and the disk-image boundary with every runtime resource intact?
#
# Usage: scripts/audit-release.sh <dmg> <version> <build> [full-source-sha]

set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-}"
EXPECTED_VERSION="${2:-}"
EXPECTED_BUILD="${3:-}"
EXPECTED_COMMIT="${4:-}"
BUNDLE_ID="com.robertnowell.voice-dispatch"
TEAM_ID="FKE587SZ6H"

fail() { echo "✗ release audit: $*" >&2; exit 1; }
pass() { echo "  ✓ $*"; }

[ -f "$DMG" ] || fail "no DMG at ${DMG:-<empty path>}"
[ -n "$EXPECTED_VERSION" ] || fail "expected version is required"
[ -n "$EXPECTED_BUILD" ] || fail "expected build is required"
DMG=$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")

echo "── auditing $(basename "$DMG") ─────────────────────────────"

codesign --verify --strict --verbose=2 "$DMG" >/dev/null 2>&1 \
  || fail "DMG signature does not verify"
DMG_SIGNATURE=$(codesign -dv --verbose=4 "$DMG" 2>&1)
case "$DMG_SIGNATURE" in
  *"Authority=Developer ID Application: Robert Nowell ($TEAM_ID)"*) ;;
  *) fail "DMG is not signed by the expected Developer ID team" ;;
esac
case "$DMG_SIGNATURE" in *"Timestamp="*) ;; *) fail "DMG has no secure timestamp" ;; esac
pass "DMG signature and secure timestamp"

xcrun stapler validate "$DMG" >/dev/null 2>&1 \
  || fail "DMG has no valid stapled notarization ticket"
DMG_ASSESS=$(/usr/sbin/spctl --assess --type open \
  --context context:primary-signature -vv "$DMG" 2>&1) || true
case "$DMG_ASSESS" in *": accepted"*"source=Notarized Developer ID"*) ;;
  *) fail "Gatekeeper does not accept the DMG as notarized Developer ID" ;;
esac
pass "stapled ticket and Gatekeeper admission"

MOUNT=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tb-release-audit.XXXXXX")
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" -eq 1 ]; then hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; fi
  rmdir "$MOUNT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" >/dev/null \
  || fail "DMG would not mount read-only"
MOUNTED=1
APP="$MOUNT/Tranquility Base.app"
INFO="$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/TranquilityApp"

[ -d "$APP" ] || fail "DMG contains no Tranquility Base.app"
[ -L "$MOUNT/Applications" ] \
  && [ "$(readlink "$MOUNT/Applications")" = "/Applications" ] \
  || fail "DMG has no working drag-to-Applications alias"
[ -x "$BIN" ] || fail "app executable is absent or not executable"
[ -f "$INFO" ] || fail "Info.plist is absent"

read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO" 2>/dev/null || true; }
[ "$(read_plist CFBundleIdentifier)" = "$BUNDLE_ID" ] \
  || fail "bundle identifier drifted"
[ "$(read_plist CFBundleShortVersionString)" = "$EXPECTED_VERSION" ] \
  || fail "bundle version is $(read_plist CFBundleShortVersionString), expected $EXPECTED_VERSION"
[ "$(read_plist CFBundleVersion)" = "$EXPECTED_BUILD" ] \
  || fail "bundle build is $(read_plist CFBundleVersion), expected $EXPECTED_BUILD"
[ "$(read_plist LSMinimumSystemVersion)" = "14.0" ] \
  || fail "minimum macOS version is not 14.0"
[ "$(read_plist LSUIElement)" = "true" ] \
  || fail "app is no longer a menu-bar-only LSUIElement"
if [ -n "$EXPECTED_COMMIT" ]; then
  [ "$(read_plist TBSourceCommit)" = "$EXPECTED_COMMIT" ] \
    || fail "bundle source commit does not match $EXPECTED_COMMIT"
fi
pass "identity, version, build, source commit and macOS floor"

# Both slices, not just the one this runner happens to be. A universal build
# that quietly loses its x86_64 half still runs perfectly on every machine we
# own, so nothing but this gate would notice until an Intel user did.
ARCHES=$(lipo -archs "$BIN")
case " $ARCHES " in *" arm64 "*) ;; *) fail "binary has no arm64 slice ($ARCHES)" ;; esac
case " $ARCHES " in *" x86_64 "*) ;; *) fail "binary has no x86_64 slice ($ARCHES)" ;; esac

# The updater has to cross the same bridge the app does. Sparkle ships a fat
# macos-arm64_x86_64 xcframework slice, so a thin framework here means the
# embedding step picked up a stale single-arch build.
SPARKLE_BIN="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle"
[ -f "$SPARKLE_BIN" ] || fail "no embedded Sparkle binary to check"
SPARKLE_ARCHES=$(lipo -archs "$SPARKLE_BIN")
case " $SPARKLE_ARCHES " in *" arm64 "*) ;; *) fail "Sparkle has no arm64 slice ($SPARKLE_ARCHES)" ;; esac
case " $SPARKLE_ARCHES " in *" x86_64 "*) ;; *) fail "Sparkle has no x86_64 slice ($SPARKLE_ARCHES)" ;; esac
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1 \
  || fail "mounted app signature does not verify"
APP_SIGNATURE=$(codesign -dv --verbose=4 "$APP" 2>&1)
case "$APP_SIGNATURE" in
  *"Authority=Developer ID Application: Robert Nowell ($TEAM_ID)"*"TeamIdentifier=$TEAM_ID"*) ;;
  *) fail "app is not signed by the expected Developer ID team" ;;
esac
case "$APP_SIGNATURE" in *"Identifier=$BUNDLE_ID"*) ;;
  *) fail "code signature identifier does not match $BUNDLE_ID" ;;
esac
case "$APP_SIGNATURE" in *"Timestamp="*) ;; *) fail "app has no secure timestamp" ;; esac
case "$APP_SIGNATURE" in *"flags=0x10000(runtime)"*) ;;
  *) fail "app was not signed with the hardened runtime" ;;
esac
APP_ASSESS=$(/usr/sbin/spctl --assess --type execute -vv "$APP" 2>&1) || true
case "$APP_ASSESS" in *": accepted"*"source=Notarized Developer ID"*) ;;
  *) fail "Gatekeeper does not accept the mounted app" ;;
esac
/usr/bin/syspolicy_check distribution "$APP" >/dev/null 2>&1 \
  || fail "syspolicy_check says the app is not ready for distribution"
DESIGNATED_REQUIREMENT=$(codesign -dr - "$APP" 2>&1)
case "$DESIGNATED_REQUIREMENT" in
  *"identifier \"$BUNDLE_ID\""*"anchor apple generic"*"certificate leaf[subject.OU] = $TEAM_ID"*) ;;
  *) fail "designated requirement is not anchored to bundle id and Developer ID team" ;;
esac
pass "universal executable, hardened runtime and app admission"

# The updater, audited on the artifact rather than trusted from the build.
#
# This block is the guard against the ONE unrecoverable mistake available here.
# A published build carrying the wrong SUFeedURL or a SUPublicEDKey that does not
# match the signing key can never be reached again by any update: it would look
# for a feed that does not exist, or reject every signature it is offered, and
# the only remedy is asking every user to download and install by hand a second
# time. Everything else in this release path can be fixed by cutting another
# release. This cannot.
EXPECTED_FEED_URL="https://updates.tranquilitybase.to/appcast.xml"
EXPECTED_ED_KEY="C/+0I+AP9TrlyA3hLSLgXdJT1kDekOXqGGnwB9bClCE="
[ "$(read_plist SUFeedURL)" = "$EXPECTED_FEED_URL" ] \
  || fail "SUFeedURL is $(read_plist SUFeedURL), expected $EXPECTED_FEED_URL"
[ "$(read_plist SUPublicEDKey)" = "$EXPECTED_ED_KEY" ] \
  || fail "SUPublicEDKey does not match the release signing key"
[ "$(read_plist SURequireSignedFeed)" = "true" ] \
  || fail "SURequireSignedFeed is not set; a tampered feed would be trusted"
[ "$(read_plist SUVerifyUpdateBeforeExtraction)" = "true" ] \
  || fail "SUVerifyUpdateBeforeExtraction is not set (SURequireSignedFeed needs it)"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$SPARKLE" ] || fail "Sparkle.framework is not embedded; this build cannot update itself"
SPARKLE_VERSION_DIR=$(cd "$SPARKLE/Versions/Current" 2>/dev/null && pwd -P) \
  || fail "Sparkle.framework has no resolvable Versions/Current"
[ ! -e "$SPARKLE_VERSION_DIR/XPCServices" ] \
  || fail "Sparkle XPC services are still embedded; they are unused and were removed deliberately"

# Every nested Mach-O carries the SAME Developer ID, hardened, timestamped. An
# outer Developer ID signature wrapped around a helper still holding the build
# job's throwaway signature does not notarize, and that is a failure that only
# appears an hour into a release.
for nested in \
  "$SPARKLE_VERSION_DIR/Autoupdate" \
  "$SPARKLE_VERSION_DIR/Updater.app" \
  "$SPARKLE"
do
  [ -e "$nested" ] || fail "Sparkle component is missing: ${nested#"$APP/"}"
  NESTED_SIGNATURE=$(codesign -dv --verbose=4 "$nested" 2>&1)
  case "$NESTED_SIGNATURE" in
    *"TeamIdentifier=$TEAM_ID"*) ;;
    *) fail "${nested#"$APP/"} is not signed by the expected Developer ID team" ;;
  esac
  case "$NESTED_SIGNATURE" in
    *"Timestamp="*) ;;
    *) fail "${nested#"$APP/"} has no secure timestamp" ;;
  esac
  case "$NESTED_SIGNATURE" in
    *"flags=0x10000(runtime)"*|*"runtime"*) ;;
    *) fail "${nested#"$APP/"} was not signed with the hardened runtime" ;;
  esac
done
pass "updater embedded, feed and key pinned, helpers signed"

ENTITLEMENTS=$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tb-entitlements.XXXXXX")
codesign -d --entitlements :- "$APP" >"$ENTITLEMENTS" 2>/dev/null \
  || fail "could not read app entitlements"
entitlement() { /usr/libexec/PlistBuddy -c "Print :$1" "$ENTITLEMENTS" 2>/dev/null || true; }
[ "$(entitlement com.apple.security.app-sandbox)" = "false" ] \
  || fail "app sandbox entitlement changed"
[ "$(entitlement com.apple.security.automation.apple-events)" = "true" ] \
  || fail "Apple Events entitlement is absent"
[ "$(entitlement com.apple.security.device.audio-input)" = "true" ] \
  || fail "audio-input entitlement is absent"
[ -z "$(entitlement com.apple.security.get-task-allow)" ] \
  || fail "debug-only get-task-allow entitlement is present"
rm -f "$ENTITLEMENTS"
pass "runtime entitlements"

[ "$(read_plist CFBundleURLTypes:0:CFBundleURLSchemes:0)" = "tranquilitybase" ] \
  || fail "primary tranquilitybase URL scheme is absent"
[ "$(read_plist CFBundleURLTypes:0:CFBundleURLSchemes:1)" = "voicedispatch" ] \
  || fail "legacy voicedispatch URL scheme is absent"
pass "stable direct-distribution and deep-link identity"

SENSITIVE_PAYLOAD=$(find "$APP" -type f \( \
  -name '.env' -o -name '*.p12' -o -name '*.pem' -o -name '*.key' \
  -o -name '*.mobileprovision' -o -name 'secrets.json' \) -print -quit)
[ -z "$SENSITIVE_PAYLOAD" ] \
  || fail "credential-shaped file was packaged: ${SENSITIVE_PAYLOAD#"$APP/"}"
pass "no credential-shaped files in the app bundle"

for resource in \
  AppIcon.icns dispatched.wav listening.wav needs-you.wav returned.wav \
  hooks/artifact-hook.sh hooks/tbase-hook.sh hooks/visual-output-hook.sh; do
  [ -f "$APP/Contents/Resources/$resource" ] \
    || fail "required resource missing: $resource"
done
for hook in "$APP/Contents/Resources/hooks/"*.sh; do
  [ -x "$hook" ] || fail "bundled hook is not executable: $(basename "$hook")"
done
pass "icon, sounds and executable hook payload"

SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "✓ release audit passed: $EXPECTED_VERSION ($EXPECTED_BUILD) $SHA256"
