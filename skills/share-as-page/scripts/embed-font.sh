#!/usr/bin/env bash
# embed-font.sh — turn a Google Font (open-source) into self-contained @font-face blocks
# with the woff2 inlined as data URIs (latin subset). Output is ready to paste into the
# template's <style>. No runtime dependency on Google — the file stays fully portable.
#
# Usage:   embed-font.sh "Family Name" [weight ...]      (default weights: 400 700)
# Example: embed-font.sh "Inter" 400 600 700
#          embed-font.sh "Fraunces" 400 700 >> fonts.css
#
# Note: works only for fonts Google serves (OFL/open-source). Proprietary foundry fonts
# (e.g. TWK Lausanne, Berkeley Mono) are NOT downloadable this way — provide the .woff2
# yourself and base64-embed it, or fall back to a system stack.
set -euo pipefail

FAMILY="${1:?usage: embed-font.sh \"Family Name\" [weights... default 400 700]}"; shift || true
WEIGHTS=("$@"); [ ${#WEIGHTS[@]} -eq 0 ] && WEIGHTS=(400 700)

# A modern browser UA is required, or Google returns legacy ttf instead of woff2.
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

fam_q="${FAMILY// /+}"
IFS=';'; wlist="${WEIGHTS[*]}"; unset IFS

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
curl -s -H "User-Agent: $UA" \
  "https://fonts.googleapis.com/css2?family=${fam_q}:wght@${wlist}&display=swap" -o "$tmp"
[ -s "$tmp" ] || { echo "error: no CSS returned for '$FAMILY' (is it an open-source Google font?)" >&2; exit 1; }

FAMILY="$FAMILY" UA="$UA" python3 - "$tmp" <<'PY'
import os, re, sys, base64, urllib.request
css = open(sys.argv[1]).read()
fam, ua = os.environ["FAMILY"], os.environ["UA"]
out = []
for blk in re.split(r'(?=/\*)', css):            # one @font-face per subset block
    if '/* latin */' not in blk:                  # keep only the latin subset
        continue
    w = re.search(r'font-weight:\s*(\d+)', blk)
    u = re.search(r'url\((https://[^)]+\.woff2)\)', blk)
    if not (w and u):
        continue
    data = urllib.request.urlopen(urllib.request.Request(u.group(1), headers={'User-Agent': ua})).read()
    b64 = base64.b64encode(data).decode()
    out.append(
        '@font-face{font-family:"%s";font-style:normal;font-weight:%s;'
        'font-display:swap;src:url(data:font/woff2;base64,%s) format("woff2")}'
        % (fam, w.group(1), b64)
    )
if not out:
    sys.exit("error: no latin woff2 found in Google CSS (non-latin-only font?)")
print("\n".join(out))
PY
