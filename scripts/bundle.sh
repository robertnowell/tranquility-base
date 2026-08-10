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

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>TranquilityApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- tranquilitybase:// deep links, so any local HTML page can carry buttons
       that open the agent that made it. The browser confirms before launching
       an external scheme, which is the drive-by guard.
       `voicedispatch` is the app's old name and stays registered: it is written
       into pages already on disk, and a footer whose button stopped working is
       worse than a footer with a stale scheme in its status bar. New pages get
       `tranquilitybase` — the scheme is visible to whoever hovers the link, so
       it has to say what the app is called. -->
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
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
fi

if [ -z "$IDENTITY" ]; then
  # Ad-hoc, but STILL with entitlements: without them the hardened-runtime denials
  # are silent (no prompt, no Privacy-pane listing). Grants may reset per rebuild;
  # creating any free Apple Development certificate in Xcode fixes that.
  echo "⚠️  no Apple Development identity found; ad-hoc signing."
  echo "   Permissions may re-prompt after rebuilds. Fix: Xcode → Settings →"
  echo "   Accounts → Manage Certificates → + Apple Development."
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
echo "On first launch it will ask for the microphone. Input Monitoring (for the"
echo "⌃⌥ hotkey) has to be granted by hand — the menu links straight to the pane."
