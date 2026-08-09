#!/bin/bash
#
# Give the app a permanent home, so quitting it is recoverable.
#
# Why this exists: until now the only copy of this app lived in
# /private/tmp/tb-clean, built there by relaunch.sh. That had four consequences,
# all of which were hit for real on 08 Aug:
#
#   1. Spotlight and Raycast could not see it — /private/tmp is not indexed — so
#      there was no way to launch it by name.
#   2. Quit was a one-way door. The menu has a Quit item (main.swift); the only
#      path back was opening a terminal and running a build script.
#   3. /private/tmp is reaped. A machine left alone for a few days can delete
#      the application outright.
#   4. Nothing started it at login, so a reboot ended with no menu bar item and
#      nothing on screen to say why.
#
# What makes this safe to do: the bundle is signed with a real Apple Development
# identity and a stable bundle id (bundle.sh finds the identity; the ad-hoc
# fallback is only for machines without one). TCC keys Microphone, Input
# Monitoring and Accessibility to the SIGNATURE, not the path — so moving the
# app does not re-prompt and does not lose the grants. Verified below rather
# than assumed: the script refuses to install an ad-hoc bundle over a signed one,
# because that IS the case where permissions would be lost.
#
# Idempotent. Run it as often as you like.
#
# Usage: scripts/install.sh [source.app] [--no-login-item]

set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-/private/tmp/tb-clean/.build/debug/Tranquility Base.app}"
[ "${1:-}" = "--no-login-item" ] && SRC="/private/tmp/tb-clean/.build/debug/Tranquility Base.app"
DEST="/Applications/Tranquility Base.app"
BUNDLE_ID="com.robertnowell.voice-dispatch"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
WANT_LOGIN_ITEM=1
for a in "$@"; do [ "$a" = "--no-login-item" ] && WANT_LOGIN_ITEM=0; done

if [ ! -d "$SRC" ]; then
  echo "✗ no bundle at $SRC" >&2
  echo "  Build one first: scripts/relaunch.sh (or scripts/bundle.sh debug)" >&2
  exit 1
fi

# --- the signature check, before anything is copied -------------------------
#
# An ad-hoc signature ("Signature=adhoc") is tied to the bytes, not to a team.
# Installing one over a Developer-signed copy is the one move that WOULD cost
# the user their permission grants, so it is refused rather than warned about.
SRC_AUTH=$(codesign -dv --verbose=2 "$SRC" 2>&1 | grep -E "^Authority=" | head -1 || true)
if [ -z "$SRC_AUTH" ]; then
  if [ -d "$DEST" ] && codesign -dv --verbose=2 "$DEST" 2>&1 | grep -q "^Authority="; then
    echo "✗ refusing: the source is ad-hoc signed and the installed copy is not." >&2
    echo "  Installing it would drop Microphone / Input Monitoring / Accessibility." >&2
    echo "  Check that a codesigning identity is visible: security find-identity -v -p codesigning" >&2
    exit 1
  fi
  echo "→ warning: ad-hoc signature. Permissions will be re-prompted after a rebuild."
else
  echo "→ signature: ${SRC_AUTH#Authority=}"
fi

# --- install ----------------------------------------------------------------
#
# The app is quit first. Copying over a running bundle is survivable here (the
# app draws its interface programmatically and loads nothing from disk after
# launch) but leaving the OLD process running against the NEW install is not:
# two instances race for one global hotkey, which is its own documented bug.
if pgrep -f "TranquilityApp" >/dev/null 2>&1; then
  echo "→ stopping the running instance"
  pkill -f "TranquilityApp" || true
  sleep 1
fi

echo "→ installing to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# Gatekeeper: a bundle that arrived by copy carries no quarantine, but strip it
# defensively so a bundle that came from anywhere else opens without a dialog.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Prove the signature survived the copy. `codesign --verify` is the check that
# actually matters for TCC — a bundle that fails it is one macOS will treat as a
# different app, permissions and all.
if codesign --verify --deep --strict "$DEST" 2>/dev/null; then
  echo "→ signature verified at the new path"
else
  echo "✗ the installed copy does not verify — macOS will treat it as a new app" >&2
  echo "  and re-prompt for every permission. Not registering a login item." >&2
  exit 1
fi

# --- login item -------------------------------------------------------------
#
# A LaunchAgent rather than an App Store login item: it needs no code in the app,
# it survives reinstalls, and macOS surfaces it to the user under
# System Settings › General › Login Items › "Allow in the Background", where it
# can be turned off without touching a terminal. That last property is why this
# is the right mechanism for someone who is not the developer.
#
# Safe to start at login because launch is silent by ruling — main.swift's
# announceLaunch speaks nothing; the idle card appearing IS the greeting. An
# app that talks at you every boot is how a login item gets disabled.
if [ "$WANT_LOGIN_ITEM" -eq 1 ]; then
  echo "→ registering the login item"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/TranquilityApp</string></array>
  <key>RunAtLoad</key><true/>
  <!-- Not KeepAlive. Quit must mean quit: a menu-bar app that relaunches itself
       when the user chooses Quit is a bug, not a feature. Login is the only
       moment this starts anything. -->
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
  # bootout then bootstrap: reloading is how an edited plist takes effect, and
  # bootout on a not-loaded agent is a harmless error.
  launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$AGENT" 2>/dev/null || true
else
  echo "→ skipping login item (--no-login-item)"
fi

# Only if nothing is up yet. `RunAtLoad` means bootstrap ALREADY started it, and
# an unconditional `open` here started a second instance — measured on the first
# run of this script. Two instances race for one global hotkey, which is the
# failure relaunch.sh has a whole comment about; an installer must not introduce
# the thing the deploy path is careful to avoid.
# `RunAtLoad` means bootstrap already asked launchd to start it, but it does so
# ASYNCHRONOUSLY — an immediate pgrep loses the race, `open` then starts a second
# copy, and two instances fight over one global hotkey. That is the failure
# relaunch.sh has a whole comment about, and the first two runs of this script
# reproduced it. So: give launchd a moment to answer before deciding.
started=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if pgrep -f "TranquilityApp" >/dev/null 2>&1; then started=1; break; fi
  sleep 0.5
done
if [ "$started" -eq 1 ]; then
  echo "→ started by the login item"
else
  echo "→ launching"
  open "$DEST"
fi
sleep 3

# One instance, always. Belt and braces: if anything above still managed to
# produce two, say so loudly rather than leaving a hotkey race running.
COUNT=$(pgrep -f "TranquilityApp" | wc -l | tr -d ' ')
if [ "$COUNT" -gt 1 ]; then
  echo "✗ $COUNT instances are running — they will fight over the global hotkey." >&2
  echo "  pkill -f TranquilityApp && open \"$DEST\"" >&2
  exit 1
fi

if pgrep -f "TranquilityApp" >/dev/null; then
  echo "✓ installed at $DEST"
  echo "  Spotlight, Raycast and the Dock can see it now, and Quit is recoverable."
  [ "$WANT_LOGIN_ITEM" -eq 1 ] && echo "  Starts at login. Turn it off in System Settings › General › Login Items."
else
  echo "✗ installed but did not stay up — check the log" >&2
  exit 1
fi
