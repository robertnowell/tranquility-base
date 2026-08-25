#!/bin/bash
#
# Build, sign, notarize, staple and publish a release DMG.
#
# WHY THIS EXISTS
#
# Until now the only way to get this app was to clone the repo and build it. That
# put a Swift 6 toolchain, Xcode Command Line Tools 16+ (macOS 14.5+), git, network
# access to the Swift package registry, and a code-signing certificate the user had
# to MANUFACTURE ON THEIR OWN MACHINE between a person and a running app — five
# things that can fail, four of them silently. Measured 24 Aug: the certificate
# script itself was broken on any Mac with Homebrew's openssl ahead of /usr/bin,
# and the failure was swallowed, so the build fell through to ad-hoc signing and
# every macOS permission died on the user's next rebuild while the Privacy pane
# kept showing them as granted.
#
# None of that is a thing a user should ever meet. This script makes the artifact
# once, here, correctly, and hands over a DMG.
#
# WHAT NOTARIZATION BUYS
#
# Two separate gates, often conflated:
#   * Gatekeeper decides whether the app may LAUNCH. It only inspects code that
#     arrived carrying com.apple.quarantine — i.e. a download. macOS 15 removed the
#     Control-click bypass, so an unnotarized download now costs the user a trip to
#     System Settings > Privacy & Security > Open Anyway. Notarizing removes it.
#   * TCC decides whether the app may use the microphone, the event tap, and so on.
#     It matches the DESIGNATED REQUIREMENT stored when the grant was made.
#
# The second is why Developer ID matters beyond the launch dialog. Signed with an
# Apple Development certificate the requirement is
#     identifier "…" and certificate leaf = H"<that exact certificate>"
# which breaks for every existing user the day the certificate is reissued. With
# Developer ID it is
#     identifier "…" and anchor apple generic and certificate leaf[subject.OU] = FKE587SZ6H
# anchored to the TEAM, so grants survive certificate renewal. Verified 25 Aug.
#
# Usage: scripts/release.sh <version>        e.g. scripts/release.sh 0.2.0
#        scripts/release.sh <version> --dry-run    build + notarize, publish nothing

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
DRY_RUN=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY_RUN=1; done

if [ -z "$VERSION" ] || [ "$VERSION" = "--dry-run" ]; then
  echo "usage: scripts/release.sh <version> [--dry-run]" >&2
  echo "       e.g. scripts/release.sh 0.2.0" >&2
  exit 1
fi

APP_NAME="Tranquility Base"
BUNDLE_ID="com.robertnowell.voice-dispatch"
TEAM_ID="FKE587SZ6H"
NOTARY_PROFILE="${TB_NOTARY_PROFILE:-AC_PASSWORD}"
STAGE=".build/release-stage"
APP_SRC=".build/release/$APP_NAME.app"
DMG_PATH=".build/TranquilityBase-$VERSION.dmg"
TAG="v$VERSION"

step() { echo; echo "── $* ─────────────────────────────────────────" ; }

# --- preflight ---------------------------------------------------------------
#
# Every one of these is a thing that fails LATE and expensively otherwise:
# notarization rejects the upload after a two-minute wait, or worse, succeeds
# against the wrong identity and ships a build whose grants die on renewal.

step "preflight"

# Rule 3 of this repo, and it applies hardest here: a dirty-tree binary once
# shipped a half-built feature that silently killed all audio. A release is the
# one build nobody can quietly replace afterwards.
if [ -n "$(git status --porcelain)" ]; then
  echo "✗ working tree is dirty — refusing to cut a release from it." >&2
  git status --short >&2
  exit 1
fi
echo "→ tree clean at $(git rev-parse --short HEAD)"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
if [ -z "$IDENTITY" ]; then
  echo "✗ no Developer ID Application identity in the keychain." >&2
  echo "  An Apple Development certificate is NOT a substitute: notarization" >&2
  echo "  rejects it, and its designated requirement pins one certificate, so" >&2
  echo "  every user's permissions would break the day it is reissued." >&2
  echo "  Create one: Xcode > Settings > Accounts > Manage Certificates > +" >&2
  echo "              > Developer ID Application" >&2
  exit 1
fi
echo "→ identity: $IDENTITY"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ no usable notarization profile '$NOTARY_PROFILE'." >&2
  echo "  Create one with an app-specific password from appleid.apple.com:" >&2
  echo "    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
  echo "      --apple-id <your-apple-id> --team-id $TEAM_ID" >&2
  exit 1
fi
echo "→ notary profile: $NOTARY_PROFILE"

if [ "$DRY_RUN" -eq 0 ] && ! gh auth status >/dev/null 2>&1; then
  echo "✗ gh is not authenticated — run: gh auth login" >&2
  exit 1
fi

# --- build -------------------------------------------------------------------

step "building $VERSION (release, arm64)"

# CFBundleVersion counts commits, so it increases monotonically without anyone
# maintaining a counter, and two releases can never collide on it.
BUILD_NUMBER=$(git rev-list --count HEAD)
echo "→ marketing version $VERSION, build $BUILD_NUMBER"

# bundle.sh assembles and signs; the identity is forced here so it cannot pick
# the Apple Development certificate that also sits in this keychain.
TB_VERSION="$VERSION" TB_BUILD="$BUILD_NUMBER" \
  VOICE_DISPATCH_SIGN_IDENTITY="$IDENTITY" \
  ./scripts/bundle.sh release >/dev/null
[ -d "$APP_SRC" ] || { echo "✗ bundle.sh produced no app at $APP_SRC" >&2; exit 1; }

# --- re-sign with a SECURE TIMESTAMP -----------------------------------------
#
# bundle.sh signs with --timestamp=none, which is right for development (the
# timestamp server is a network round trip on every incremental build) and fatal
# here: notarization REQUIRES a secure timestamp and rejects the submission
# without one. Signing inside-out — nested code first, bundle last — because
# codesign seals what it finds, and a later inner change invalidates the outer
# seal.
step "signing with a secure timestamp"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
  --entitlements TranquilityBase.entitlements \
  --options runtime --timestamp \
  "$APP_SRC"

codesign --verify --deep --strict --verbose=2 "$APP_SRC"

# Captured ONCE into a variable, then tested without a pipeline.
#
# The obvious spelling of this check is a lie under `set -o pipefail`:
#
#     if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "^Timestamp="
#
# `grep -q` exits the instant it matches, which closes the pipe; codesign then
# dies of SIGPIPE and the pipeline reports 141. pipefail propagates that, `!`
# inverts it, and the guard fires ON SUCCESS -- it rejects exactly the correctly
# timestamped signature it exists to require. Measured 25 Aug on this script's
# own first dry run, against a signature whose Timestamp= line was printed two
# lines above the error saying it had none.
SIGN_INFO=$(codesign -dv --verbose=4 "$APP_SRC" 2>&1)
echo "$SIGN_INFO" | grep -E "^(Authority|TeamIdentifier|Timestamp)=" || true

# A signature with no secure timestamp is rejected by the notary service minutes
# from now; catching it here costs nothing.
case "$SIGN_INFO" in
  *"Timestamp="*) ;;
  *)  echo "✗ no secure timestamp on the signature — notarization would reject this." >&2
      exit 1 ;;
esac

# --- DMG ---------------------------------------------------------------------
#
# hdiutil rather than create-dmg: it is part of macOS, so this script has no
# Homebrew dependency and works on a machine that has never installed anything.
# The Applications symlink is what makes the window a drag-to-install.
step "building the disk image"
rm -rf "$STAGE" "$DMG_PATH"
mkdir -p "$STAGE"
cp -R "$APP_SRC" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
  "$DMG_PATH" >/dev/null
rm -rf "$STAGE"
echo "→ $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

# The DMG is signed too. Not strictly required — the notarized, stapled ticket is
# what Gatekeeper reads — but an unsigned container is one more thing for a
# security-conscious user to squint at.
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"

# --- notarize ----------------------------------------------------------------

step "notarizing (this takes a few minutes)"
if ! xcrun notarytool submit "$DMG_PATH" \
      --keychain-profile "$NOTARY_PROFILE" --wait; then
  echo "✗ notarization failed. For the reasons:" >&2
  echo "    xcrun notarytool history --keychain-profile $NOTARY_PROFILE" >&2
  echo "    xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
fi

# Stapling attaches the ticket to the DMG so it validates OFFLINE. Without it a
# first launch on a machine with no network falls back to an online check that
# cannot complete, and the user gets the dialog notarization was meant to remove.
step "stapling"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# The honest end-to-end check: ask the same subsystem Gatekeeper asks, and
# REFUSE to publish if it does not say "accepted". Everything above can succeed
# while the artifact is still one a user's Mac will not open.
#
# /usr/sbin/spctl by absolute path. It is not on every PATH -- this script's own
# first successful run died here with `spctl: command not found`, AFTER notarizing,
# because the invoking environment had no /usr/sbin. Third instance of one class
# on this branch (openssl, then codesign-under-pipefail, now this): a tool
# resolved through the environment is a tool that works until someone else runs it.
step "verifying as Gatekeeper sees it"
ASSESS=$(/usr/sbin/spctl --assess --type open \
  --context context:primary-signature -vv "$DMG_PATH" 2>&1) || true
echo "$ASSESS" | sed 's/^/   /'
case "$ASSESS" in
  *": accepted"*) ;;
  *)  echo "✗ Gatekeeper does not accept this DMG — not publishing it." >&2
      exit 1 ;;
esac

# --- publish -----------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "✓ dry run complete — notarized and stapled, nothing published."
  echo "  $DMG_PATH"
  exit 0
fi

step "publishing $TAG"
gh release create "$TAG" "$DMG_PATH" \
  --repo robertnowell/tranquility-base \
  --title "Tranquility Base $VERSION" \
  --notes "Signed and notarized. Download the DMG, drag the app to Applications, open it.

First launch opens a checklist: grant Microphone, Input Monitoring and Accessibility, and the dots go green as you do. Requires macOS 14 or later on Apple silicon, the \`claude\` CLI, and \`tmux\`." \
  --latest

echo
echo "✓ released $TAG"
echo "  https://github.com/robertnowell/tranquility-base/releases/latest"
