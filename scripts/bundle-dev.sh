#!/bin/bash
# Build the persistent development identity from the same TranquilityApp target.
# Only the macOS identity envelope differs from production.
set -euo pipefail
cd "$(dirname "$0")/.."

export VD_APP_NAME="Tranquility Base Dev"
export VD_BUNDLE_ID="com.robertnowell.voice-dispatch.dev"
export VD_APP_CHANNEL="development"
export VD_UPDATES_ENABLED="false"
export VD_URL_SCHEMES="tranquilitybase voicedispatch tbdev"
export TB_FEED_URL="https://updates.tranquilitybase.to/dev-appcast.xml"

exec scripts/bundle.sh "${1:-debug}"
