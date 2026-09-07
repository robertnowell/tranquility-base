#!/bin/bash
#
# Install an exact published release at the production path.
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
# Production is deliberately narrower than Dev: this accepts only the expected
# notarized Developer ID identity. Local builds belong at the Dev path, even if
# they use the production bundle id, because swapping signing requirements at
# one path is what invalidates macOS privacy grants.
#
# Idempotent. Run it as often as you like.
#
# Usage: scripts/install.sh source.app [--no-login-item]

set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/lib/app-process.sh"
DEST="/Applications/Tranquility Base.app"
BUNDLE_ID="com.robertnowell.voice-dispatch"
TEAM_ID="FKE587SZ6H"
LOGIN_LABEL="$BUNDLE_ID.selected"
AGENT="$HOME/Library/LaunchAgents/$LOGIN_LABEL.plist"
WANT_LOGIN_ITEM=1
SRC=""
for arg in "$@"; do
  case "$arg" in
    --no-login-item) WANT_LOGIN_ITEM=0 ;;
    *) [ -z "$SRC" ] || { echo "✗ more than one source app" >&2; exit 2; }; SRC="$arg" ;;
  esac
done
if [ -z "$SRC" ]; then
  echo "✗ a published Tranquility Base.app source is required" >&2
  echo "  Local source builds belong in Dev: scripts/install-dev.sh" >&2
  exit 2
elif [ ! -d "$SRC" ]; then
  echo "✗ no bundle at $SRC" >&2
  echo "  Mount or download the published release artifact, then pass its app path." >&2
  exit 1
fi

# The production destination is sacred. An explicit path is allowed so a
# downloaded release can be installed, but its identity must still be the
# production identity; otherwise this script would recreate the collision this
# split exists to end by putting Dev bytes at the Prod path.
SRC_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
  "$SRC/Contents/Info.plist" 2>/dev/null || echo "")
if [ "$SRC_BUNDLE_ID" != "$BUNDLE_ID" ]; then
  echo "✗ refusing to install bundle id ${SRC_BUNDLE_ID:-missing} at $DEST" >&2
  echo "  Production requires $BUNDLE_ID; use scripts/install-dev.sh for Dev." >&2
  exit 1
fi

# --- the release identity check, before anything is copied -----------------
codesign --verify --deep --strict "$SRC" 2>/dev/null \
  || { echo "✗ source signature does not verify" >&2; exit 1; }
SRC_SIGNING=$(codesign -dv --verbose=4 "$SRC" 2>&1 || true)
case "$SRC_SIGNING" in
  *"Authority=Developer ID Application: Robert Nowell ($TEAM_ID)"*"TeamIdentifier=$TEAM_ID"*) ;;
  *)
    echo "✗ Prod accepts only the expected Developer ID release identity" >&2
    echo "  Local Apple Development builds belong in Dev: scripts/install-dev.sh" >&2
    exit 1 ;;
esac
SRC_ASSESS=$(/usr/sbin/spctl --assess --type execute -vv "$SRC" 2>&1 || true)
case "$SRC_ASSESS" in
  *": accepted"*"source=Notarized Developer ID"*) ;;
  *) echo "✗ Prod source is not an accepted notarized release" >&2; exit 1 ;;
esac
echo "→ signature: Developer ID Application: Robert Nowell ($TEAM_ID)"

# --- install ----------------------------------------------------------------
#
# The app is quit first. Copying over a running bundle is survivable here (the
# app draws its interface programmatically and loads nothing from disk after
# launch) but leaving the OLD process running against the NEW install is not:
# two instances race for one global hotkey, which is its own documented bug.
app_stop

echo "→ installing to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# Gatekeeper: a bundle that arrived by copy carries no quarantine, but strip it
# defensively so a bundle that came from anywhere else opens without a dialog.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Prove the release signature survived the copy. A bundle that fails this is
# not merely a different TCC identity; it is not a valid production app.
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
  <key>Label</key><string>$LOGIN_LABEL</string>
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
  # Retire the pre-channel label. Leaving both loaded makes login a race in
  # which whichever identity gets the ownership lock first wins.
  launchctl bootout "gui/$UID/$BUNDLE_ID" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
  launchctl bootout "gui/$UID/$LOGIN_LABEL" 2>/dev/null || true
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
  if app_at_path_running "$DEST"; then started=1; break; fi
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
COUNT=$(app_count)
if [ "$COUNT" -gt 1 ]; then
  echo "✗ $COUNT instances are running — they will fight over the global hotkey." >&2
  echo "  pkill -f \"$APP_PROC_PATTERN\" && open \"$DEST\"" >&2
  exit 1
fi

if app_at_path_running "$DEST"; then
  echo "✓ installed at $DEST"
  echo "  Spotlight, Raycast and the Dock can see it now, and Quit is recoverable."
  [ "$WANT_LOGIN_ITEM" -eq 1 ] && echo "  Starts at login. Turn it off in System Settings › General › Login Items."
else
  echo "✗ installed but did not stay up — check the log" >&2
  exit 1
fi
