#!/bin/bash
#
# Advertise a release that already exists.
#
# The appcast is the promotion switch, deliberately separate from the artifact.
# Bytes are published first, immutably, and audited; only then does the feed say
# they exist. If this script fails, users stay on the previous advertised build
# and nothing is broken. That ordering is the whole reason it is a separate step
# rather than another asset uploaded beside the DMG.
#
# The feed lives on the `gh-pages` branch, NOT on main. Every commit to main in
# this repository is a release, so a feed-only commit to main would cut an entire
# new build. The release workflow triggers on main alone, so pushing here is
# inert.
#
# Usage: scripts/publish-appcast.sh <dmg> <version> <build> <tag> [--dry-run]

set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-}"
VERSION="${2:-}"
BUILD="${3:-}"
TAG="${4:-}"
DRY_RUN=0
[ "${5:-}" = "--dry-run" ] && DRY_RUN=1

REPO="robertnowell/tranquility-base"
FEED_BRANCH="gh-pages"
FEED_DOMAIN="updates.tranquilitybase.to"
# Keep a bounded history. Sparkle only ever offers the newest eligible item, but
# older entries make the feed readable by a human debugging "why was I offered
# that", and a file that grows forever eventually is the bug.
KEEP_ITEMS=10

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo; echo "── $*"; }

[ -f "$DMG" ] || fail "no DMG at ${DMG:-<empty>}"
[ -n "$VERSION" ] || fail "version is required"
[ -n "$BUILD" ] || fail "build number is required"
[ -n "$TAG" ] || fail "tag is required"

# Sparkle's signing tool, which this job may or may not already have.
#
# Locally, and in the build job, `swift build` has fetched the Sparkle SPM
# artifact and the tool sits under .build/artifacts. The SIGNING job has neither:
# it checks out release tooling, downloads the prebuilt app from the build job,
# and never compiles anything. So the tool is fetched on demand, pinned by
# version AND by the same SHA-256 that SwiftPM verifies the binary target
# against, from Sparkle's own release.
#
# `|| true` on the find is load-bearing. Without it, `find` on a .build/artifacts
# that does not exist returns non-zero, pipefail propagates it through the
# assignment, and `set -e` kills the script BEFORE the `fail` below can say why.
# That is exactly how 0.3.1064 published its DMG and then died here in 0.1s with
# no output at all, which cost more time to diagnose than the bug was worth.
SPARKLE_VERSION="2.9.6"
SPARKLE_SHA256="8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"

SIGN_UPDATE=$(find .build/artifacts -name sign_update -type f -perm +111 2>/dev/null | head -1 || true)
if [ -z "$SIGN_UPDATE" ]; then
  echo "→ no local Sparkle tooling; fetching $SPARKLE_VERSION"
  TOOLS=$(mktemp -d)
  ZIP="$TOOLS/sparkle.zip"
  curl -fsSL -o "$ZIP" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip" \
    || fail "could not download Sparkle $SPARKLE_VERSION"
  ACTUAL=$(shasum -a 256 "$ZIP" | awk '{print $1}')
  [ "$ACTUAL" = "$SPARKLE_SHA256" ] \
    || fail "Sparkle $SPARKLE_VERSION checksum is $ACTUAL, expected $SPARKLE_SHA256"
  unzip -q -o "$ZIP" -d "$TOOLS"
  SIGN_UPDATE="$TOOLS/bin/sign_update"
  chmod +x "$SIGN_UPDATE"
  echo "→ verified Sparkle $SPARKLE_VERSION against its pinned checksum"
fi
[ -x "$SIGN_UPDATE" ] || fail "no usable sign_update tool"

# The private key never touches the runner's disk. In CI it arrives as an
# environment secret and goes straight down a pipe; locally, sign_update falls
# back to the login Keychain, which is where generate_keys put it.
sign_with_key() {
  if [ -n "${TB_SPARKLE_EDDSA_PRIVATE_KEY:-}" ]; then
    printf '%s' "$TB_SPARKLE_EDDSA_PRIVATE_KEY" | "$SIGN_UPDATE" "$@" --ed-key-file -
  else
    "$SIGN_UPDATE" "$@"
  fi
}

step "signing the archive"
# Prints: sparkle:edSignature="..." length="..."
ENCLOSURE_ATTRS=$(sign_with_key "$DMG")
case "$ENCLOSURE_ATTRS" in
  *'sparkle:edSignature="'*) ;;
  *) fail "sign_update produced no signature: $ENCLOSURE_ATTRS" ;;
esac
echo "→ $ENCLOSURE_ATTRS"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

step "fetching the current feed"
if git ls-remote --exit-code --heads origin "$FEED_BRANCH" >/dev/null 2>&1; then
  git fetch -q origin "$FEED_BRANCH"
  # `git archive`, never `git checkout --work-tree`. That form writes the files
  # into $WORK but ALSO stages them in THIS repository's index, so the release
  # checkout is left dirty with three feed files it has no business tracking.
  # It happened: a local run left CNAME, appcast.xml and index.html staged as
  # deletions after the temp directory was cleaned up, and preflight refused the
  # tree. In CI the runner is ephemeral so it would have gone unnoticed, right
  # up until something committed with `git add -A`. Archive touches no index.
  git archive "origin/$FEED_BRANCH" | tar -x -C "$WORK"
  EXISTING=$(grep -c '<item>' "$WORK/appcast.xml" 2>/dev/null || true)
  echo "→ existing feed with ${EXISTING:-0} item(s)"
else
  echo "→ no $FEED_BRANCH branch yet; this run creates it"
fi

step "merging this release into the feed"
DMG_NAME=$(basename "$DMG")
ENCLOSURE_URL="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"
export ENCLOSURE_ATTRS ENCLOSURE_URL VERSION BUILD KEEP_ITEMS FEED_DOMAIN
python3 - "$WORK/appcast.xml" <<'PY'
import os, re, sys, datetime, xml.etree.ElementTree as ET

path = sys.argv[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")

version = os.environ["VERSION"]
build = os.environ["BUILD"]
attrs = os.environ["ENCLOSURE_ATTRS"]
url = os.environ["ENCLOSURE_URL"]
keep = int(os.environ["KEEP_ITEMS"])

signature = re.search(r'sparkle:edSignature="([^"]+)"', attrs).group(1)
length = re.search(r'length="([^"]+)"', attrs).group(1)

if os.path.exists(path):
    tree = ET.parse(path)
    root = tree.getroot()
    channel = root.find("channel")
else:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Tranquility Base"
    ET.SubElement(channel, "link").text = f"https://{os.environ['FEED_DOMAIN']}/appcast.xml"
    ET.SubElement(channel, "description").text = "Updates for Tranquility Base."
    ET.SubElement(channel, "language").text = "en"
    tree = ET.ElementTree(root)

def build_of(item):
    node = item.find(f"{{{SPARKLE}}}version")
    try:
        return int(node.text)
    except (AttributeError, TypeError, ValueError):
        return -1

# Replace rather than duplicate, so a reissued release does not appear twice.
for existing in [i for i in channel.findall("item") if build_of(i) == int(build)]:
    channel.remove(existing)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {version}"
# sparkle:version is what Sparkle actually compares, and it is CFBundleVersion:
# the git ancestry count, which is monotonic by construction. The marketing
# string is only ever shown to a person.
ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
# Mirrors what audit-release.sh already asserts about the bundle itself, so a
# machine that cannot run this build is never offered it.
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
ET.SubElement(item, "pubDate").text = datetime.datetime.now(
    datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
ET.SubElement(item, "enclosure", {
    "url": url,
    "type": "application/octet-stream",
    "length": length,
    f"{{{SPARKLE}}}edSignature": signature,
})
channel.insert(len(list(channel)), item)

items = sorted(channel.findall("item"), key=build_of, reverse=True)
for existing in channel.findall("item"):
    channel.remove(existing)
for keeper in items[:keep]:
    channel.append(keeper)

ET.indent(tree, space="  ")
tree.write(path, encoding="utf-8", xml_declaration=True)
print(f"feed now advertises {len(items[:keep])} build(s), newest {build}")
PY

step "signing the feed"
# SURequireSignedFeed is YES in the app, so an unsigned feed is simply ignored by
# every installed copy. The signature is embedded in the XML itself.
sign_with_key "$WORK/appcast.xml" --disable-signing-warning
# sign_update appends the feed signature as a trailing "sparkle-signatures"
# comment block rather than an attribute, so this is what proves it ran. Nothing
# may modify the file after this point: the signature covers its bytes.
grep -q 'sparkle-signatures' "$WORK/appcast.xml" \
  || fail "appcast was not signed; installed copies would ignore it"

# A CNAME file is how GitHub Pages knows to answer on our domain. Written every
# time so a hand edit on the branch cannot quietly drop it.
printf '%s\n' "$FEED_DOMAIN" > "$WORK/CNAME"

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "✓ dry run: feed built and signed, nothing pushed"
  echo
  cat "$WORK/appcast.xml"
  exit 0
fi

step "publishing the feed"
git -C "$WORK" init -q
git -C "$WORK" checkout -q -b "$FEED_BRANCH"
git -C "$WORK" add appcast.xml CNAME
git -C "$WORK" -c user.name="tranquility-base release" \
  -c user.email="release@$FEED_DOMAIN" \
  commit -q -m "Advertise $VERSION (build $BUILD)"
# Force-push a single-commit branch: the feed is generated state, not history,
# and its history is the release list on main.
git -C "$WORK" push -q --force \
  "$(git remote get-url origin)" "$FEED_BRANCH:$FEED_BRANCH"

echo
echo "✓ advertised $VERSION at https://$FEED_DOMAIN/appcast.xml"
