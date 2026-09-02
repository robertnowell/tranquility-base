#!/bin/bash
#
# Build the exact source-stamped app before any release credential enters the
# runner. The signing job replaces this ad-hoc signature with Developer ID.
#
# Usage: scripts/prepare-release-app.sh

set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/lib/paths.sh"

TARGET=$(git rev-parse HEAD)
BUILD_NUMBER=$(git rev-list --count "$TARGET")
RELEASE_SERIES="${TB_RELEASE_SERIES:-0.3}"
VERSION="$RELEASE_SERIES.$BUILD_NUMBER"
APP="$(tb_bundle_dir release)/Tranquility Base.app"

case "$VERSION" in
  *[!0-9.]*|.*|*..*|*.) echo "invalid release version: $VERSION" >&2; exit 1 ;;
esac

TB_VERSION="$VERSION" TB_BUILD="$BUILD_NUMBER" TB_SOURCE_COMMIT="$TARGET" \
  VOICE_DISPATCH_SIGN_IDENTITY=- ./scripts/bundle.sh release >/dev/null

[ -d "$APP" ] || { echo "bundle.sh produced no app at $APP" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
echo "✓ assembled unsigned release input: $VERSION ($BUILD_NUMBER) at $TARGET"
