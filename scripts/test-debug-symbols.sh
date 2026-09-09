#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/App.app/Contents/MacOS" "$FIXTURE/App.dSYM"
touch "$FIXTURE/App.app/Contents/MacOS/TranquilityApp"
cat > "$FIXTURE/bin/dwarfdump" <<'MOCK'
#!/bin/bash
case "$2" in
  *.dSYM) [ "${DSYM_EMPTY:-0}" = 1 ] && exit 0
           echo "UUID: ${DSYM_UUID:-AABB} (arm64) fixture"
           [ "${DSYM_ONE_SLICE:-0}" = 1 ] && exit 0 ;;
  *) echo 'UUID: AABB (arm64) fixture' ;;
esac
echo 'UUID: CCDD (x86_64) fixture'
MOCK
cat > "$FIXTURE/bin/sentry-cli" <<'MOCK'
#!/bin/bash
[[ "$*" == *"--wait"* ]] || exit 4
exit "${UPLOAD_STATUS:-0}"
MOCK
chmod +x "$FIXTURE/bin/"*
export PATH="$FIXTURE/bin:$PATH"
export SENTRY_AUTH_TOKEN=fixture-token
check() { scripts/check-debug-symbols.sh "$FIXTURE/App.app" "$FIXTURE/App.dSYM" >/dev/null 2>&1; }
upload() { scripts/upload-debug-symbols.sh "$FIXTURE/App.app" "$FIXTURE/App.dSYM" >/dev/null 2>&1; }
refuses() { if "$@"; then echo "FAIL: unexpectedly accepted invalid symbols/upload" >&2; exit 1; fi; }
check
DSYM_UUID=DIFFERENT refuses check
DSYM_ONE_SLICE=1 refuses check
DSYM_EMPTY=1 refuses check
SENTRY_AUTH_TOKEN='' refuses upload
UPLOAD_STATUS=1 refuses upload
upload
mv "$FIXTURE/App.dSYM" "$FIXTURE/removed"
refuses check
echo '✓ debug-symbol checks: matching slices, mismatch, missing slice, empty/missing bundle, missing token, upload failure, processed upload'
