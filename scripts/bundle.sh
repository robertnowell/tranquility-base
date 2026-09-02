#!/bin/bash
#
# Assemble TranquilityApp into a real .app bundle and sign it.
#
# A bare SwiftPM executable cannot hold the two things this app needs:
#   - LSUIElement, so it lives in the menu bar with no dock icon
#   - NSMicrophoneUsageDescription, without which the mic prompt never appears and
#     the process is killed the moment it touches AVAudioEngine
#
# And TCC keys its grants to bundle identifier + code signature, so both must stay
# fixed across rebuilds or every permission has to be granted again. That is the
# same trap that made the keychain re-prompt on every `swift build`.
#
# Usage: scripts/bundle.sh [debug|release]
#
# APP_NAME and BUNDLE_ID are overridable (VD_APP_NAME, VD_BUNDLE_ID) so
# scripts/bundle-test.sh can stamp out a SEPARATE app -- different bundle
# id, different code identity, so TCC treats it as an entirely different
# app with its own, independently resettable permission grants. Every
# other caller of this script (relaunch.sh, preflight.sh) leaves both
# unset and gets the real app, unchanged.

set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=lib/paths.sh
. "$(dirname "$0")/lib/paths.sh"

CONFIG="${1:-debug}"
# Overridable so release.sh can stamp a real version without editing this file.
# CFBundleVersion must increase for every build macOS is asked to distinguish;
# the marketing version is what a human reads.
APP_VERSION="${TB_VERSION:-0.1.0}"
# The line above this one has said "CFBundleVersion must increase for every
# build macOS is asked to distinguish" since the day it was written, and the
# line below it defaulted to the constant 1. So every build ever made carried
# the same version, and every crash report said `ver: 1`.
#
# That cost real time on 27 Aug. Five crashes in one day across five unrelated
# subsystems, and the first question — WHICH BUILD DIED — had no answer in the
# report. Attribution had to be reconstructed from log timestamps against the
# deploy ledger, for a fact the bundle could simply have carried.
#
# Two keys, because they answer different questions and a crash report prints
# both. CFBundleVersion is the commit COUNT: monotonic and numeric, which is
# what "must increase" actually requires and what LaunchServices caches on. The
# short version carries the SHA, which is the part a human greps the deploy
# ledger for. A tree without git (a tarball, a sandbox) falls back to the old
# constants rather than failing a build over provenance.
if _tb_sha=$(git rev-parse --short HEAD 2>/dev/null) \
   && _tb_count=$(git rev-list --count HEAD 2>/dev/null); then
  APP_VERSION="${TB_VERSION:-0.1.0+$_tb_sha}"
  APP_BUILD="${TB_BUILD:-$_tb_count}"
  SOURCE_COMMIT="${TB_SOURCE_COMMIT:-$(git rev-parse HEAD)}"
else
  APP_BUILD="${TB_BUILD:-1}"
  SOURCE_COMMIT="${TB_SOURCE_COMMIT:-unknown}"
fi
APP_NAME="${VD_APP_NAME:-Tranquility Base}"
BUNDLE_ID="${VD_BUNDLE_ID:-com.robertnowell.voice-dispatch}"

# Architectures. Universal by default so Intel Macs are covered; a single arch
# stays available for fast local iteration (TB_ARCHS=arm64 scripts/bundle.sh).
#
# The output path is ASKED FOR, never assumed. A multi-arch `swift build` does
# not write to .build/<config>: it redirects to .build/apple/Products/<Config>,
# with the configuration capitalised. Hardcoding either layout is how a bundle
# silently ships the previous single-arch binary, and `--show-bin-path` reports
# both correctly for the cost of one extra invocation.
read -r -a TB_ARCH_LIST <<< "${TB_ARCHS:-arm64 x86_64}"
ARCH_ARGS=()
for _tb_arch in "${TB_ARCH_LIST[@]}"; do ARCH_ARGS+=(--arch "$_tb_arch"); done
PRODUCTS_DIR=$(swift build --configuration "$CONFIG" "${ARCH_ARGS[@]}" --show-bin-path)

# NOT .build/$CONFIG. See lib/paths.sh for the two ways SwiftPM destroys a
# bundle left in its own tree.
BUILD_DIR=$(tb_bundle_dir "$CONFIG")

# shellcheck source=lib/sparkle.sh
. "$(dirname "$0")/lib/sparkle.sh"

# The update feed, and the key that proves an update came from us.
#
# Compiled in rather than fetched, because SUFeedURL is the ONE piece of
# configuration an installed copy can never be told to change: a copy only
# learns about a new feed through the feed it already has. It is a domain we
# own (not a github.io URL) so hosting can move later without stranding
# anybody. audit-release.sh asserts both of these on the artifact, because a
# published build with the wrong feed or the wrong key is permanently
# unreachable and costs a second manual reinstall.
#
# Overridable so bundle-test.sh can point a throwaway app at a throwaway feed.
TB_FEED_URL="${TB_FEED_URL:-https://updates.tranquilitybase.to/appcast.xml}"
TB_PUBLIC_ED_KEY="${TB_PUBLIC_ED_KEY:-C/+0I+AP9TrlyA3hLSLgXdJT1kDekOXqGGnwB9bClCE=}"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

swift build --configuration "$CONFIG" "${ARCH_ARGS[@]}" --product TranquilityApp

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
mkdir -p "$BUILD_DIR"
cp "$PRODUCTS_DIR/TranquilityApp" "$APP_DIR/Contents/MacOS/TranquilityApp"

# The earcon set. Four short files, ~160KB total, loaded by name through
# Bundle.main in Earcons.swift. Flat in Resources/ rather than in a SwiftPM
# resource bundle, because this .app is assembled by hand and a
# `Bundle.module` lookup would need that bundle copied in too — one more
# thing to forget. If these are missing the app still runs; it just goes
# silent, and Earcons logs "no audio for <cue>".
cp Resources/Sounds/*.wav "$APP_DIR/Contents/Resources/"

# The Claude Code hooks travel INSIDE the bundle.
#
# Until now they lived only in the repo, and settings.json pointed at that
# checkout by absolute path — so hooks broke whenever the repo moved, and a user
# handed a built .app had no hooks at all, because there was no repo to point at.
# HookManifest documents the moved-repo case as failure mode 3; bundling is what
# actually closes it, because a path inside the app moves with the app.
#
# Copied, not symlinked: codesign seals Contents/Resources, and a symlink out of
# the bundle would point at a checkout the user may not have.
mkdir -p "$APP_DIR/Contents/Resources/hooks"
cp hooks/*.sh "$APP_DIR/Contents/Resources/hooks/"
chmod +x "$APP_DIR/Contents/Resources/hooks/"*.sh

# Sparkle, before anything else touches the bundle.
#
# Two constraints, and this is the only point that satisfies both. It has to be
# BEFORE the icon step below, because that step EXECUTES the bundled binary to
# draw the icon, and the binary links @rpath/Sparkle.framework: with no
# framework and no rpath, dyld cannot load it, the process dies, and the bundle
# silently ships with no AppIcon.icns. And it has to be BEFORE signing, because
# the outer signature seals everything inside Contents/, so a framework copied
# in afterwards invalidates it.
#
# Found the expensive way on 2 Sep: embedding sat next to the signing block, the
# icon step warned "could not draw the iconset" into a wall of build output, and
# the first hosted release got all the way through notarizing the app AND the
# DMG before audit-release.sh refused it for a missing icon. The audit did its
# job; the warning did not, because a warning nobody reads is not a signal.
sparkle_embed "$APP_DIR" "$PRODUCTS_DIR"

# The app icon, drawn by the app itself.
#
# Generated rather than checked in: the mark lives in SiteMark.swift, so the
# icon and the menu-bar glyph come from one path and cannot drift. The binary
# is already built at this point, so it draws its own icon — `--write-iconset`
# exits before NSApplication, taking no lock and registering no hotkey.
#
# Why this matters at all: the app shipped with NO icon for its whole life.
# LSUIElement hides the Dock tile most of the time, so nobody noticed — but
# onboarding flips the app to .regular, which put the GENERIC DEFAULT icon in
# the Dock and ⌘-Tab at exactly the moment a new user meets it.
ICONSET="$(mktemp -d)/AppIcon.iconset"
# The test build's icon is unmistakable at a glance (SiteMark.swift's
# `isTestBuild`, keyed on this same env var): an amber plate instead of the
# real app's, so it never gets confused with it in the Dock or Cmd-Tab.
#
# `env` as the no-op prefix, not an empty array: `"${ICON_ENV[@]}"` on an
# EMPTY array is an unbound-variable error under `set -u` in bash 3.2,
# which is what /usr/bin/env bash still is on macOS -- broke the REAL
# app's own build the first time this shipped, on a bash that never
# takes the test-build branch below at all. scripts/test.sh's own
# comment already documents this exact trap; reproduced it anyway.
ICON_ENV=(env)
[ "$BUNDLE_ID" = "com.robertnowell.voice-dispatch-test" ] \
  && ICON_ENV=(env VOICE_DISPATCH_TEST_ICON=1)
if "${ICON_ENV[@]}" "$APP_DIR/Contents/MacOS/TranquilityApp" --write-iconset "$ICONSET" >/dev/null; then
  if iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"; then
    echo "→ icon: AppIcon.icns"
  else
    echo "✗ iconutil failed — the bundle will show the default icon" >&2
  fi
else
  echo "✗ could not draw the iconset — the bundle will show the default icon" >&2
fi
rm -rf "$(dirname "$ICONSET")"

# Set only when VD_DATA_DIR is provided (scripts/bundle-test.sh's isolated
# build): baked into the bundle's own Info.plist as LSEnvironment, which
# LaunchServices applies to every launch of THIS app however it is opened
# (Dock, Spotlight, `open`) -- unlike `launchctl setenv`, which is a global,
# per-session override with no guarantee it reaches a launch that races it
# (measured live, 26 Aug: it didn't). QueueStore.swift reads this as
# VOICE_DISPATCH_SUPPORT_DIR. Empty for the real app, so its Info.plist is
# byte-identical to before.
#
# MALLOC DIAGNOSTICS, ON DELIBERATELY AND TEMPORARILY. Added 29 Aug 2026,
# alongside the AEDesc double-free fix (fdb9edb). The Aug 27 session proposed
# exactly this and it was never actually switched on, so when the next crash
# came the stack still only named the victim. It is ON BY DEFAULT rather than
# behind an env var on purpose: deploys here come from whichever session merges
# next, and an opt-in flag none of them set is an opt-in flag that is off. The
# cost is a slower malloc and some memory; the return is that the next crash
# names who freed the memory instead of who touched it afterwards.
#
# Deliberately NOT MallocScribble or MallocErrorAbort: both make latent
# corruption crash sooner, which would corrupt the very measurement this
# window exists to take (is the crash rate now zero?). Add them only if a
# crash actually appears and we need it to fail faster.
#
# REMOVE AFTER 1 SEP 2026 if the soak is clean. Delete this block and the
# MallocStackLogging entry below.
MALLOC_DIAG_XML="
    <key>MallocStackLogging</key><string>1</string>"

LS_ENV_XML=""
if [ -n "${VD_DATA_DIR:-}" ]; then
  LS_ENV_XML="  <key>LSEnvironment</key>
  <dict>
    <key>VOICE_DISPATCH_SUPPORT_DIR</key><string>$VD_DATA_DIR</string>$MALLOC_DIAG_XML
  </dict>"
else
  LS_ENV_XML="  <key>LSEnvironment</key>
  <dict>$MALLOC_DIAG_XML
  </dict>"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>TranquilityApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <!-- The release number tells people which build they have; this binds those
       bytes to the exact source commit the automated release built. Unlike the
       marketing version it is never chosen or rewritten by a release job. -->
  <key>TBSourceCommit</key><string>$SOURCE_COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>

  <!-- Sparkle. SURequireSignedFeed means the appcast DOCUMENT is signed, not
       just each download: per-enclosure signatures prove the bytes you fetched
       are ours, but not that the entry pointing at them was. The feed lives on
       a host we do not fully control, so the document gets signed too.
       SUVerifyUpdateBeforeExtraction is its prerequisite. -->
  <key>SUFeedURL</key><string>$TB_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$TB_PUBLIC_ED_KEY</string>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SURequireSignedFeed</key><true/>
  <!-- tranquilitybase:// deep links, so any local HTML page can carry buttons
       that open the agent that made it. The browser confirms before launching
       an external scheme, which is the drive-by guard.
       The voicedispatch scheme is the app's old name and stays registered: it
       is written into pages already on disk, and a footer whose button stopped
       working is worse than a footer with a stale scheme in its status bar. New
       pages get tranquilitybase, because the scheme is visible to whoever
       hovers the link and it has to say what the app is called.
       NOTE: this heredoc is unquoted, so backticks here become command
       substitution. A backticked scheme name in this comment silently ate the
       scheme it was documenting (10 Aug) — the app built, signed, launched, and
       simply had no tranquilitybase:// registration. Keep prose plain. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Tranquility Base actions</string>
      <key>CFBundleURLSchemes</key>
      <array><string>tranquilitybase</string><string>voicedispatch</string></array>
    </dict>
  </array>

  <!-- Menu bar only: no dock icon, no main window. -->
  <key>LSUIElement</key><true/>

  <!-- Shown in the microphone prompt. Without this key the process is terminated
       the moment it touches AVAudioEngine, with no prompt at all. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>Tranquility Base records your spoken reply so it can be transcribed and sent back to the coding session that asked for it. Audio stays on this Mac unless you configure a cloud transcription provider.</string>

  <!-- "Go to session" and dispatch both drive Terminal via Apple Events. Without
       this key the request is denied silently and the app never appears under
       Privacy > Automation — the same failure mode the microphone had. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>Tranquility Base focuses the terminal tab a session is running in, and types your dictated reply into it.</string>

  <!-- Only needed if Apple's on-device recogniser is used as the fallback tier. -->
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Tranquility Base can transcribe your reply on-device when no cloud provider is available, so a recording is never lost.</string>
$LS_ENV_XML
</dict>
</plist>
PLIST

IDENTITY="${VOICE_DISPATCH_SIGN_IDENTITY:-}"
# Must match make-signing-identity.sh. Overridable by the same variable so the
# create-from-nothing path is testable without rotating the real certificate.
LOCAL_CN="${VD_SIGN_CN:-Voice Dispatch Local Signing}"
if [ -z "$IDENTITY" ]; then
  # `|| true` is load-bearing: with `pipefail`, grep finding nothing fails the whole
  # pipeline, and under `set -e` that aborts the script *before* the ad-hoc branch
  # below — so the machine that needs the fallback most is the one that never
  # reaches it, and you are left with an unsigned bundle whose missing entitlements
  # deny every permission silently.
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)

  # Fall back to the local self-signed identity from scripts/make-signing-identity.sh.
  #
  # This exists because ad-hoc signing is not merely inconvenient, it is unusable:
  # an ad-hoc designated requirement is `cdhash H"..."`, which changes on EVERY
  # build, so TCC treats each rebuild as a different application and silently voids
  # Accessibility, Input Monitoring and the microphone. Worse, the Privacy pane keeps
  # showing the old row as enabled, so it reads as "granted but broken" and there is
  # nothing in the UI to fix. `-p codesigning` alone will not list this certificate
  # (it is untrusted, CSSMERR_TP_NOT_TRUSTED), but codesign signs with it happily and
  # the resulting requirement is identifier + certificate — stable across rebuilds.
  if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
      | grep "$LOCAL_CN" | head -1 \
      | sed -E 's/^ *[0-9]+\) ([0-9A-F]+) .*/\1/' || true)
  fi

  # Still nothing: CREATE the identity rather than warning and shipping an ad-hoc
  # build. A warning was not good enough. Ad-hoc signing does not degrade the app in
  # some tolerable way — it makes permissions unfixable, and it does so while the
  # Privacy pane insists everything is granted. Nobody reads a warning and infers
  # that, so the first run has to be correct by construction rather than by advice.
  if [ -z "$IDENTITY" ]; then
    echo "no code-signing identity found — creating a stable local one (once)."
    # Output is NOT swallowed, and the failure is NOT swallowed either beyond
    # letting the ad-hoc branch below report it. `>/dev/null 2>&1 || true` hid a
    # real breakage for weeks (25 Aug): the script failed on every machine with
    # Homebrew's openssl ahead of /usr/bin, and the only visible symptom was
    # permissions that silently died on the next rebuild. If this script fails,
    # its own diagnostics are the most useful thing on screen.
    "$(dirname "$0")/make-signing-identity.sh" || \
      echo "   (make-signing-identity.sh failed — see its output above)"
    IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
      | grep "$LOCAL_CN" | head -1 \
      | sed -E 's/^ *[0-9]+\) ([0-9A-F]+) .*/\1/' || true)
    [ -n "$IDENTITY" ] && echo "created a stable signing identity; grants will now survive rebuilds."
  fi
fi

if [ -z "$IDENTITY" ]; then
  # Reached only if identity creation itself failed. Still sign ad-hoc WITH
  # entitlements — without them the hardened-runtime denials are silent — but say
  # plainly what will go wrong, because the symptom is otherwise unrecognisable.
  echo "⚠️  could not create a signing identity; falling back to ad-hoc."
  echo "   Consequence: every rebuild voids your macOS permissions, while the"
  echo "   Privacy pane keeps showing them as granted. If that happens, run"
  echo "   scripts/reset-permissions.sh and grant again."
  echo "   Retry the identity with: scripts/make-signing-identity.sh"
  sparkle_sign "$APP_DIR" - --timestamp=none
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --entitlements TranquilityBase.entitlements \
    --options runtime --timestamp=none "$APP_DIR"
else
  # --entitlements is not optional here. With the hardened runtime enabled, a
  # protected resource needs the entitlement as well as the Info.plist usage string;
  # without it TCC denies instantly, shows no prompt, and never lists the app in the
  # Privacy pane — a completely silent failure.
  # Nested first, outer last, never --deep: see scripts/lib/sparkle.sh.
  sparkle_sign "$APP_DIR" "$IDENTITY" --timestamp=none
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
    --entitlements TranquilityBase.entitlements \
    --options runtime --timestamp=none "$APP_DIR"
  echo "signed as: $IDENTITY"
fi

echo "built: $APP_DIR"
echo
echo "Run it:    open \"$APP_DIR\""
echo "Stop it:   pkill -f TranquilityApp"
echo
echo "On first launch the checklist appears; nothing is asked until you press"
echo "Grant on a row. Grant ACCESSIBILITY for the gestures -- the checklist"
echo "links straight to the pane -- then relaunch once, since"
echo "macOS only evaluates that grant when the process starts."
