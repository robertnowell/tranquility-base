#!/usr/bin/env bash
# shot.sh — render a local HTML file to a PNG with headless Chrome so it can be
# visually inspected BEFORE deploying. Part of the required visual-eval gate.
#
# Usage:   shot.sh <html-file-or-dir> [out.png] [width] [height]
# Example: shot.sh ./index.html /tmp/preview.png 1300 1100
# Then:    Read the PNG and actually look at it — centering, overflow, contrast,
#          logo, spacing — and fix before running deploy.sh.
set -euo pipefail

SRC="${1:?usage: shot.sh <html-file-or-dir> [out.png] [w] [h]}"
[ -d "$SRC" ] && SRC="$SRC/index.html"
[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }
OUT="${2:-/tmp/share-as-page-preview.png}"
W="${3:-1300}"; H="${4:-1100}"

# Resolve a Chrome/Chromium binary across common install paths.
CHROME=""
for c in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "$(command -v google-chrome 2>/dev/null || true)" \
  "$(command -v chromium 2>/dev/null || true)" \
  "$(command -v chromium-browser 2>/dev/null || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && CHROME="$c" && break
done
[ -n "$CHROME" ] || { echo "error: no Chrome/Chromium found for screenshotting" >&2; exit 1; }

# Absolute file:// URL.
case "$SRC" in /*) ABS="$SRC";; *) ABS="$PWD/$SRC";; esac

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --screenshot="$OUT" --window-size="${W},${H}" "file://${ABS}" >/dev/null 2>&1

[ -s "$OUT" ] || { echo "error: screenshot produced no output" >&2; exit 1; }
echo "$OUT"
