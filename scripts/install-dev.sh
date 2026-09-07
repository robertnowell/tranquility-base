#!/bin/bash
# Install the stable local-development identity without touching production.
#
# Usage: scripts/install-dev.sh [source.app] [--activate]
# With no source, the current committed, clean branch is bundled as Dev.
set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/lib/paths.sh"
. "$(dirname "$0")/lib/app-process.sh"

APP_NAME="Tranquility Base Dev"
BUNDLE_ID="com.robertnowell.voice-dispatch.dev"
DEST="/Applications/$APP_NAME.app"
SRC=""
ACTIVATE=0
for arg in "$@"; do
  case "$arg" in
    --activate) ACTIVATE=1 ;;
    *) [ -z "$SRC" ] || { echo "✗ more than one source app" >&2; exit 1; }; SRC="$arg" ;;
  esac
done

if [ -z "$SRC" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "✗ the worktree is dirty; commit before building an app to launch." >&2
    git status --short >&2
    exit 1
  fi
  scripts/bundle-dev.sh debug
  SRC="$(tb_bundle_dir debug)/$APP_NAME.app"
fi

[ -d "$SRC" ] || { echo "✗ no bundle at $SRC" >&2; exit 1; }
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$SRC/Contents/Info.plist" 2>/dev/null; }
[ "$(read_plist CFBundleIdentifier)" = "$BUNDLE_ID" ] \
  || { echo "✗ source is not the Dev bundle id" >&2; exit 1; }
[ "$(read_plist TBAppChannel)" = "development" ] \
  || { echo "✗ source is not stamped as the development channel" >&2; exit 1; }
[ "$(read_plist TBUpdatesEnabled)" = "false" ] \
  || { echo "✗ Dev updater is enabled; refusing to install" >&2; exit 1; }
codesign --verify --deep --strict "$SRC" 2>/dev/null \
  || { echo "✗ Dev source signature does not verify" >&2; exit 1; }

SOURCE_SIGNING=$(codesign -dv --verbose=2 "$SRC" 2>&1 || true)
case "$SOURCE_SIGNING" in
  *$'\nAuthority='*|Authority=*) ;;
  *) echo "✗ Dev is ad-hoc signed; its permissions would reset next build" >&2; exit 1 ;;
esac
SOURCE_AUTHORITIES=$(printf '%s\n' "$SOURCE_SIGNING" | sed -n 's/^Authority=//p')
SOURCE_AUTH="${SOURCE_AUTHORITIES%%$'\n'*}"

# A stable bundle id is only half of TCC's identity. Refuse to replace a Dev
# install if its designated requirement changed, unless a person explicitly
# accepts the resulting one-time permission reset.
if [ -d "$DEST" ]; then
  OLD_REQUIREMENT=$(codesign -dr - "$DEST" 2>&1 \
    | sed -n 's/^designated => //p' || true)
  NEW_REQUIREMENT=$(codesign -dr - "$SRC" 2>&1 \
    | sed -n 's/^designated => //p' || true)
  if [ -n "$OLD_REQUIREMENT" ] && [ "$OLD_REQUIREMENT" != "$NEW_REQUIREMENT" ] \
     && [ "${TB_ALLOW_DEV_IDENTITY_CHANGE:-0}" != "1" ]; then
    echo "✗ Dev's signing requirement changed; refusing to reset its permissions." >&2
    echo "  Set TB_ALLOW_DEV_IDENTITY_CHANGE=1 only for a deliberate identity rotation." >&2
    exit 1
  fi
  app_stop_path "$DEST"
fi

echo "→ installing $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --verify --deep --strict "$DEST" 2>/dev/null \
  || { echo "✗ installed Dev bundle does not verify" >&2; exit 1; }

echo "✓ installed Dev without touching /Applications/Tranquility Base.app"
echo "  signature: $SOURCE_AUTH"
if [ "$ACTIVATE" -eq 1 ]; then
  exec scripts/switch-app.sh dev
fi
