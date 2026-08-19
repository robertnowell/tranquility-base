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

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="Tranquility Base"
BUNDLE_ID="com.robertnowell.voice-dispatch"
BUILD_DIR=".build/$CONFIG"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

swift build --configuration "$CONFIG" --product TranquilityApp

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/TranquilityApp" "$APP_DIR/Contents/MacOS/TranquilityApp"

# The earcon set. Four short files, ~160KB total, loaded by name through
# Bundle.main in Earcons.swift. Flat in Resources/ rather than in a SwiftPM
# resource bundle, because this .app is assembled by hand and a
# `Bundle.module` lookup would need that bundle copied in too — one more
# thing to forget. If these are missing the app still runs; it just goes
# silent, and Earcons logs "no audio for <cue>".
cp Resources/Sounds/*.wav "$APP_DIR/Contents/Resources/"

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
if "$APP_DIR/Contents/MacOS/TranquilityApp" --write-iconset "$ICONSET" >/dev/null; then
  if iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"; then
    echo "→ icon: AppIcon.icns"
  else
    echo "✗ iconutil failed — the bundle will show the default icon" >&2
  fi
else
  echo "✗ could not draw the iconset — the bundle will show the default icon" >&2
fi
rm -rf "$(dirname "$ICONSET")"

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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
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
    "$(dirname "$0")/make-signing-identity.sh" >/dev/null 2>&1 || true
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
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" \
    --entitlements TranquilityBase.entitlements \
    --options runtime --timestamp=none "$APP_DIR"
else
  # --entitlements is not optional here. With the hardened runtime enabled, a
  # protected resource needs the entitlement as well as the Info.plist usage string;
  # without it TCC denies instantly, shows no prompt, and never lists the app in the
  # Privacy pane — a completely silent failure.
  codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
    --entitlements TranquilityBase.entitlements \
    --options runtime --timestamp=none "$APP_DIR"
  echo "signed as: $IDENTITY"
fi

echo "built: $APP_DIR"
echo
echo "Run it:    open \"$APP_DIR\""
echo "Stop it:   pkill -f TranquilityApp"
echo
echo "On first launch it will ask for the microphone. Grant ACCESSIBILITY for the"
echo "gestures — the checklist links straight to the pane — then relaunch once, since"
echo "macOS only evaluates that grant when the process starts."
