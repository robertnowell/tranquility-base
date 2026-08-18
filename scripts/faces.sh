#!/bin/bash
#
# Shoot every panel face under BOTH monospaced faces, so a font swap can be
# checked rather than hoped about.
#
# Ruled 18 Aug, when the panel started preferring Berkeley Mono if the machine
# has it: "now we have to verify compatibility everywhere we go between Berkeley
# and the system fallback." Two builds of the same pixels is the only honest way
# to see it — the drills can hold the arithmetic (marks on the line, nothing
# clipped) but not the taste, and the taste is the reason for the swap.
#
# Uses --pose-shot, which renders from the view hierarchy: no Screen Recording
# grant, no awake display, and (since the pose block moved above the hotkey) no
# second event tap racing the running app.
#
# Usage: scripts/faces.sh [outdir]        default: /tmp/tb-faces
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/tb-faces}"
APP="$(pwd)/.build/debug/TranquilityApp"
POSES="grid speaking needsyou depth1 waiting listening transcribing receipt-card settings recent-audio collapsed empty"

[ -x "$APP" ] || { echo "✗ build first: swift build" >&2; exit 1; }
mkdir -p "$OUT/berkeley" "$OUT/system"

for pose in $POSES; do
  "$APP" --allow-second-instance --pose-shot "$pose" "$OUT/berkeley/$pose.png" >/dev/null 2>&1 || true
  TB_MONO=system "$APP" --allow-second-instance --pose-shot "$pose" "$OUT/system/$pose.png" >/dev/null 2>&1 || true
done

echo "→ $OUT"
for pose in $POSES; do
  b="$OUT/berkeley/$pose.png"; s="$OUT/system/$pose.png"
  if [ -f "$b" ] && [ -f "$s" ]; then
    bs=$(stat -f%z "$b"); ss=$(stat -f%z "$s")
    printf "  %-16s berkeley %7d  system %7d\n" "$pose" "$bs" "$ss"
  else
    printf "  %-16s (not rendered)\n" "$pose"
  fi
done
echo "Open both directories side by side; the arithmetic is the chrome drill's job, this is the eye's."
