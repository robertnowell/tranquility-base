#!/usr/bin/env bash
# check-brand.sh — deterministic brand-provenance linter for share-as-page.
#
# Catches the failure modes a visual eval structurally cannot: invented tokens,
# unsourced colours, and fonts that are named but never embedded (so the page
# silently renders in a fallback and still looks fine).
#
# Usage:  check-brand.sh <html-file-or-dir>
# Exit:   0 = pass, 1 = fail. Called by deploy.sh as a hard gate.
#
# NOTE: deliberately no `set -o pipefail`. `grep -q` exits on first match and
# SIGPIPEs its upstream; under pipefail that reads as a failed pipeline and
# produced false "font not embedded" failures on correct pages. A noisy gate
# gets bypassed, which is worse than no gate — keep this quiet and precise.

set -u

SRC="${1:?usage: check-brand.sh <html-file-or-dir>}"
[ -d "$SRC" ] && SRC="$SRC/index.html"
[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }

FAIL=0
say()  { printf '  %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
good() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '  \033[33m·\033[0m %s\n' "$1"; }

printf '\nBrand provenance check — %s\n\n' "$SRC"

# ---------------------------------------------------------------- provenance
if ! grep -qi 'PROVENANCE' "$SRC"; then
  bad "No PROVENANCE block. Every page must record where its tokens came from."
  bad "See SKILL.md §2a — resolve the brand, or declare the page unbranded."
  printf '\nFAILED\n\n'
  exit 1
fi
good "PROVENANCE block present"

PROV=$(awk '/PROVENANCE/,/\*\//' "$SRC")

UNBRANDED=0
if grep -qi 'unbranded' <<< "$PROV"; then
  good "Declared unbranded (neutral defaults) — legitimate, and visible to the reader"
  UNBRANDED=1
elif grep -qiE 'brand:[[:space:]]*[A-Za-z0-9]' <<< "$PROV"; then
  BRAND=$(grep -iE 'brand:' <<< "$PROV" | head -1 | sed 's/^[^:]*: *//' | cut -c1-60)
  good "Brand named: $BRAND"
else
  bad "PROVENANCE names no brand and does not declare 'unbranded'."
fi

if grep -qE '<value>|<where>|rung <n>' <<< "$PROV"; then
  bad "PROVENANCE still contains template placeholders — not filled in."
fi

# ---------------------------------------------------- identity-token sourcing
# Only IDENTITY tokens must carry an explicit rung. Supporting tokens
# (paper/muted/line/bg/text/on-brand) are routinely legitimate neutrals even on
# a fully resolved brand — demanding a rung for each just trains people to
# pad the ledger. An unbranded page needs none of this.
IDENTITY="--color-brand --color-accent --color-heading --font-heading --font-body"

if [ "$UNBRANDED" -eq 1 ]; then
  note "Unbranded — skipping per-token sourcing (the declaration covers it)"
else
  ROOT=$(awk '/:root[[:space:]]*\{/,/^[[:space:]]*\}/' "$SRC")
  MISSING=""
  for tok in $IDENTITY; do
    # Only demand a rung for identity tokens the page actually declares.
    grep -q -- "$tok:" <<< "$ROOT" || continue
    grep -q -- "$tok" <<< "$PROV" || MISSING="$MISSING $tok"
  done
  if [ -n "$MISSING" ]; then
    bad "Identity tokens missing from PROVENANCE:"
    for t in $MISSING; do say "    $t"; done
    say "  A token with no rung is invented. Resolve it, or declare the page unbranded."
  else
    good "Every identity token carries a rung"
  fi

  # The brand colour itself must not still be the shipped neutral grey.
  ROOT=$(awk '/:root[[:space:]]*\{/,/^[[:space:]]*\}/' "$SRC")
  BRANDVAL=$(grep -oE '^[[:space:]]*--color-brand:[^;]*' <<< "$ROOT" | sed 's/^[^:]*: *//')
  case "$BRANDVAL" in
    *3f3f46*|*1f2a44*)
      bad "--color-brand is still a template default ($BRANDVAL) while claiming a brand." ;;
    *) [ -n "$BRANDVAL" ] && good "--color-brand is a resolved value ($BRANDVAL)" ;;
  esac
fi

# ------------------------------------------------------------------- fonts
# A named non-system family with no matching @font-face renders as a silent
# fallback — invisible to every other check, including the visual eval.
ROOT=${ROOT:-$(awk '/:root[[:space:]]*\{/,/^[[:space:]]*\}/' "$SRC")}
SYSTEM_RE='ui-sans-serif|ui-serif|ui-monospace|-apple-system|BlinkMacSystemFont|system-ui|Segoe UI|Helvetica|Arial|Georgia|Times|Courier|Menlo|Consolas|SFMono|monospace|sans-serif|serif'
DECLARED=$(grep -oE '^[[:space:]]*--font-[a-z-]+:[^;]*' <<< "$ROOT" | sed 's/^[^:]*://')
CUSTOM=$(grep -oE '"[^"]+"' <<< "$DECLARED" | tr -d '"' | grep -vE "$SYSTEM_RE" | sort -u)

if [ -n "$CUSTOM" ]; then
  FACES=$(awk '/@font-face/,/\}/' "$SRC")
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if grep -qF "$f" <<< "$FACES"; then
      good "Font \"$f\" is embedded (@font-face present)"
    else
      bad "Font \"$f\" is named with NO matching @font-face — it will render as a fallback."
      say "  Embed it (scripts/embed-font.sh) or use a system stack and say so."
    fi
  done <<< "$CUSTOM"
else
  good "System font stack only — nothing to embed"
fi

# --------------------------------------------------------- self-containment
# Only fetched subresources count. An <a href> is a hyperlink the reader may click —
# it makes no request on load and is exactly what a citation should be. Flagging those
# would fail every correctly-sourced report.
#
# ONE EXCEPTION, and it is off until a bucket exists: media served from the
# archive's own asset origin. 72 of 1756 pages hold inline images and those 72
# carry 94.6 MB, 35% of all the HTML on disk, so images are the one class worth
# moving out. Type and favicons stay inline — a page must still LOOK right with
# the network off, and a font is the difference between right and wrong.
#
# The origin is read from hq.json (assets.base_url). Unset means unset: the rule
# below is exactly as absolute as it was before this paragraph existed. That is
# deliberate — the config value is the single switch, so nothing can start
# pointing outward because a regex was too generous.
ASSET_HOST=$(python3 - <<'PYEOF' 2>/dev/null
import json, os, pathlib
# Same resolution order publish.py uses, so the two halves of the system
# cannot be looking at different configs while agreeing they agree.
try:
    p = os.environ.get("HQ_CONFIG") or (pathlib.Path.home() / ".claude" / "hq.json")
    cfg = json.loads(pathlib.Path(p).expanduser().read_text())
    print((cfg.get("assets") or {}).get("base_url") or "")
except Exception:
    print("")
PYEOF
)

EXT=$(grep -oE 'src="https?://[^"]*|url\((["'"'"']?)https?://[^)]*|<link[^>]+href="https?://[^"]*' "$SRC")

# Drop the allowed media references before judging what is left. Matching on
# the CONFIGURED PREFIX rather than on "looks like an image" is the point: a
# .png on somebody else's CDN is still an outside dependency, and a page that
# renders only while that host is up is not a page this archive keeps.
ALLOWED=0
if [ -n "$ASSET_HOST" ] && [ -n "$EXT" ]; then
  ALLOWED=$(grep -cF "$ASSET_HOST" <<< "$EXT")
  EXT=$(grep -vF "$ASSET_HOST" <<< "$EXT")
fi

if [ -n "$EXT" ]; then
  bad "External subresource found — the page must be self-contained (inline/data: URIs)."
  say "  Scripts, stylesheets, fonts and third-party media all count. Only $ASSET_HOST is exempt."
  head -3 <<< "$EXT" | while IFS= read -r u; do say "    $u"; done
else
  if [ "$ALLOWED" -gt 0 ]; then
    good "Self-contained apart from $ALLOWED asset(s) on $ASSET_HOST"
  else
    good "Self-contained — no fetched external subresources"
  fi
  LINKS=$(grep -c 'href="https\?://' "$SRC")
  [ "$LINKS" -gt 0 ] && note "$LINKS outbound hyperlink(s) — fine, these are citations, not requests"
fi

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mPASSED\033[0m\n\n'; exit 0
else
  printf '\033[31mFAILED\033[0m — fix the tokens, not the layout. See SKILL.md §2a.\n\n'; exit 1
fi
