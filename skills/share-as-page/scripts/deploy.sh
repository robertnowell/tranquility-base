#!/usr/bin/env bash
# share-as-page deploy — push a directory containing index.html to a shareable URL.
# Primary: Vercel (non-interactive, persistent alias). Reads VERCEL_TOKEN from env if set,
# else uses ambient `vercel login`. Prints the live URL on success.
#
# Usage: deploy.sh <project-dir>
set -euo pipefail

DIR="${1:?usage: deploy.sh <project-dir containing index.html>}"
[ -f "$DIR/index.html" ] || { echo "error: $DIR/index.html not found" >&2; exit 1; }

# HQ content (research briefs, internal docs) is hosted by the central publisher as one
# project with deterministic URLs — never as a per-directory Vercel project.
HQ_DIR="$(hq-root legacy 2>/dev/null || echo "$HOME/Documents/deep-research")"
case "$(cd "$DIR" && pwd)" in
  "$HQ_DIR"/*)
    echo "error: $DIR is HQ content. Set visibility: hosted in its metadata and run:" >&2
    echo "       python3 ~/Projects/intranet/build.py --deploy" >&2
    exit 1;;
esac

# Hard gate: no page ships with unsourced brand tokens. Set SKIP_BRAND_CHECK=1 only
# for a deliberate, stated exception — never to make a red check go away.
if [ "${SKIP_BRAND_CHECK:-0}" != "1" ]; then
  CHECK="$(dirname "$0")/check-brand.sh"
  if [ -x "$CHECK" ] || [ -f "$CHECK" ]; then
    bash "$CHECK" "$DIR" || {
      echo "error: brand provenance check failed — not deploying." >&2
      echo "       Fix the tokens (SKILL.md §2a), or re-run with SKIP_BRAND_CHECK=1 if you" >&2
      echo "       have a stated reason and have told the user the page is off-brand." >&2
      exit 1
    }
  fi
fi

# Vercel requires CLI >= 47.2 (Aug 2026) and that CLI needs Node >= 18. The machine's default
# node is 16 and the global `vercel` is 39.x, so prefer the newest nvm Node and run the
# latest CLI via npx. Override with VERCEL_BIN if you want a specific binary.
NVM_NODE="$(ls -d "$HOME"/.nvm/versions/node/v2[0-9]* 2>/dev/null | sort -V | tail -1)"
[ -n "$NVM_NODE" ] && export PATH="$NVM_NODE/bin:$PATH"
VERCEL_BIN="${VERCEL_BIN:-npx -y vercel@latest}"
command -v npx >/dev/null 2>&1 || command -v vercel >/dev/null 2>&1 || {
  echo "error: neither npx nor vercel CLI found. Install Node >= 18 (nvm) or npm i -g vercel@latest" >&2
  exit 1
}

cd "$DIR"

# --prod promotes to the production alias; --yes suppresses all setup prompts.
# An unlinked dir now REQUIRES an explicit scope (the new CLI emits guidance JSON instead of
# deploying). Default to the rendition team unless the caller overrides or the dir is linked.
[ -z "${VERCEL_SCOPE:-}" ] && [ ! -f .vercel/project.json ] && VERCEL_SCOPE=rendition
out="$($VERCEL_BIN deploy --prod --yes ${VERCEL_SCOPE:+--scope=$VERCEL_SCOPE} 2>&1)" || { echo "$out" >&2; exit 1; }

# Prefer the clean aliased URL; fall back to any *.vercel.app in the output.
url="$(printf '%s\n' "$out" | grep -i 'Aliased:' | grep -oE 'https://[^ ]+\.vercel\.app' | tail -1 || true)"
[ -z "$url" ] && url="$(printf '%s\n' "$out" | grep -oE 'https://[a-z0-9.-]+\.vercel\.app' | head -1 || true)"
# Newer CLI output has no "Aliased:" line; prefer the project's stable alias when the dir is linked.
if [ -f .vercel/project.json ]; then
  pn="$(python3 -c 'import json;print(json.load(open(".vercel/project.json")).get("projectName",""))' 2>/dev/null)"
  # newer CLIs omit projectName from project.json; the project is named after the dir by convention
  [ -z "$pn" ] && pn="$(basename "$DIR")"
  alias_url="https://$pn.vercel.app"
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$alias_url" 2>/dev/null | grep -qE '^(200|30[0-9])$' && url="$alias_url"
fi

if [ -z "$url" ]; then
  echo "$out" >&2
  echo "error: deployed but could not parse a URL from vercel output" >&2
  exit 1
fi

# The hub keeps a copy. A page that lives only in a project directory and a
# Vercel alias is on no agent's hub and in no archive: the 10 Sep case was a
# published order-status page that the hub never listed. If index.html says
# which session wrote it (intranet:session), file a copy under that agent's
# directory carrying the live address, so the local hub, the cloud hub and the
# archive index all show "published" beside it. The copy is the record; the
# project directory is the build.
session="$(grep -oE '<meta name="intranet:session" content="[0-9a-f-]{8,}"' index.html 2>/dev/null | head -1 | sed -E 's/.*content="([^"]*)"/\1/')"
if [ -n "$session" ] && [ -d "$HOME/Documents/agents" ]; then
  agentdir="$HOME/Documents/agents/$session"
  slug="$(basename "$DIR")"
  copy="$agentdir/$slug.html"
  if [ -d "$agentdir" ] && [ "$copy" != "$agentdir/index.html" ]; then
    python3 - "$url" "$copy" <<'PY'
import re, sys
url, out = sys.argv[1], sys.argv[2]
html = open("index.html", encoding="utf-8", errors="replace").read()
html = re.sub(r'<meta name="intranet:url"[^>]*>\n?', '', html)
html = re.sub(r'(<meta name="intranet:visibility" content=")[^"]*(")', r'\1hosted\2', html)
tag = '<meta name="intranet:url" content="%s">' % url
html = re.sub(r'(<meta name="intranet:session"[^>]*>)', r'\1\n' + tag.replace('\\', '\\\\'), html, count=1) \
       if '<meta name="intranet:session"' in html else html.replace('<head>', '<head>\n' + tag, 1)
open(out, "w", encoding="utf-8").write(html)
PY
    python3 "$(cd "$(dirname "$0")/../../research-hq/scripts" && pwd)/publish.py" >/dev/null 2>&1 || true
    echo "filed: $copy" >&2
  fi
fi

echo "$url"
