#!/bin/bash
#
# Build and sign with a STABLE identity.
#
# Why this exists: `swift build` ad-hoc signs its binaries, and an ad-hoc signature
# has no stable identity — the keychain's designated requirement for the trusted app
# falls back to the binary's cdhash. That hash changes on every rebuild, so macOS
# treats each build as a brand-new application and re-prompts for keychain access no
# matter how many times you click "Always Allow".
#
# Signing with a real identity and a fixed bundle identifier makes the requirement
# identifier + team, which survives rebuilds. Grant once, done.
#
# Usage: scripts/build.sh [release]

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
IDENTITY="${VOICE_DISPATCH_SIGN_IDENTITY:-}"

if [ -z "$IDENTITY" ]; then
  # See bundle.sh: without `|| true`, a machine with no certificate exits here
  # under `set -e` instead of reaching the ad-hoc warning below.
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
fi

swift build ${CONFIG:+--configuration "$CONFIG"}

BIN_DIR=".build/$CONFIG"

if [ -z "$IDENTITY" ]; then
  echo "⚠️  no Apple Development identity found — binaries stay ad-hoc signed."
  echo "   The keychain will re-prompt on every rebuild. Set"
  echo "   VOICE_DISPATCH_SIGN_IDENTITY to override."
  exit 0
fi

for tool in tbase tbase-test-target; do
  [ -f "$BIN_DIR/$tool" ] || continue
  codesign --force --sign "$IDENTITY" \
    --identifier "com.robertnowell.voice-dispatch.$tool" \
    --options runtime \
    "$BIN_DIR/$tool" 2>/dev/null \
    || codesign --force --sign "$IDENTITY" \
         --identifier "com.robertnowell.voice-dispatch.$tool" \
         "$BIN_DIR/$tool"
done

echo "built and signed ($CONFIG) as: $IDENTITY"
echo "The first keychain prompt after this will stick — the signing identity no"
echo "longer changes between builds."
