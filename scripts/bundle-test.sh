#!/bin/bash
#
# A SEPARATE app, as far as macOS is concerned, for testing the first-run /
# onboarding experience without ever touching the real app's permissions OR
# its data.
#
# TWO isolation facts, not one:
#
# 1. TCC keys every grant to bundle identifier + code signature (bundle.sh's
#    own comment explains why both have to be stable). A different bundle
#    id and macOS has no way to connect this build to "Tranquility Base" at
#    all: a fresh row in every Privacy pane, reset independently, with zero
#    effect on the real app's own grants.
# 2. `QueueStore.supportDirectory` is a HARDCODED path, not keyed to bundle
#    id at all: the queue database, session ownership, secrets.json (real
#    API keys), the capture marker. Found live, 26 Aug: fact 1 alone reads
#    as "isolated" and is not. A build isolated only on TCC still shares
#    every byte of real data with the real app the moment both are running,
#    which is exactly what happened here. `VOICE_DISPATCH_SUPPORT_DIR`
#    (QueueStore.swift) is what fact 2 needed, and this script is its one
#    caller.
#
# Runs from .build/debug directly rather than installing to /Applications:
# this is a throwaway testing rig, not a second real install, and skipping
# /Applications means there is nothing there to ever confuse with the real
# app or a Spotlight search for it.
#
# Usage:
#   scripts/bundle-test.sh              # build (or rebuild) the test app
#   scripts/bundle-test.sh --reset      # clear ITS TCC grants and ITS data, then build
#   scripts/bundle-test.sh --open       # build, then open it (isolated data dir)
#   scripts/bundle-test.sh --reset --open   # the common one: fresh onboarding, now

set -euo pipefail
cd "$(dirname "$0")/.."

export VD_APP_NAME="Tranquility Base TEST"
export VD_BUNDLE_ID="com.robertnowell.voice-dispatch-test"
APP_PATH=".build/debug/$VD_APP_NAME.app"
DATA_DIR="$HOME/Library/Application Support/VoiceDispatchTEST"
# Baked into the built .app's Info.plist as LSEnvironment (bundle.sh), so
# every launch of THIS app carries it, however it is opened. Fixed and
# deterministic across runs of this script, so a rebuild always bakes in
# the same value.
export VD_DATA_DIR="$DATA_DIR"

# No separate signing identity needed: TCC's designated requirement is
# identifier + certificate, and the identifier alone (VD_BUNDLE_ID above)
# already differs from the real app's. bundle.sh signs this with whatever
# it would sign the real app with (the same Apple Development certificate,
# most likely) and that is fine, isolation comes from the bundle id.

for arg in "$@"; do
  case "$arg" in
    --reset)
      if pgrep -f "$APP_PATH/Contents/MacOS" >/dev/null 2>&1; then
        echo "-> quitting the test app first (its authorisation is decided at launch)"
        pkill -f "$APP_PATH/Contents/MacOS" || true
        sleep 1
      fi
      echo "-> clearing TCC grants for $VD_BUNDLE_ID (the TEST app only; the real"
      echo "   app's bundle id is different and is never touched by this)"
      for service in Accessibility ListenEvent Microphone AppleEvents SpeechRecognition; do
        out=$(tccutil reset "$service" "$VD_BUNDLE_ID" 2>&1) && echo "  reset $service" \
          || echo "  reset $service: $out"
      done
      echo "-> wiping the test app's own data dir ($DATA_DIR)"
      rm -rf "$DATA_DIR"
      ;;
  esac
done

bash scripts/bundle.sh debug

for arg in "$@"; do
  case "$arg" in
    --open)
      mkdir -p "$DATA_DIR"
      echo "-> opening $APP_PATH (data dir: $DATA_DIR)"
      # `open -a`, not a direct exec of the binary: found live, 26 Aug, that
      # a directly-executed child of this shell inherited Terminal's own
      # Accessibility/Input Monitoring trust (macOS's "responsible process"
      # attribution for a process that never went through LaunchServices),
      # so every permission read back as already granted no matter what
      # tccutil said. `open -a` launches through LaunchServices like a real
      # double-click would, which is what actually produces real,
      # un-granted system prompts.
      #
      # No env-var juggling needed here any more: VD_DATA_DIR above is
      # already baked into this exact build's Info.plist (bundle.sh's
      # LSEnvironment), so `open -a` alone carries it correctly. An earlier
      # version of this tried `launchctl setenv`/`unsetenv` around the
      # launch instead, and measured live that it does not reliably reach
      # the new process before this script's own `unsetenv` -- the test
      # app wrote straight into the REAL app's queue.sqlite and app.log
      # again, twice, before this was caught both times.
      open --new -a "$PWD/$APP_PATH" --args --allow-second-instance
      ;;
  esac
done

echo
echo "Test app:  $APP_PATH  (bundle id: $VD_BUNDLE_ID)"
echo "Data dir:  $DATA_DIR  (never the real app's)"
echo "Open it:   scripts/bundle-test.sh --open"
echo "Fresh run: scripts/bundle-test.sh --reset --open"
echo "Stop it:   pkill -f \"$APP_PATH/Contents/MacOS\""
echo
echo "Never touches the real Tranquility Base's permissions OR its data:"
echo "different bundle id (separate Privacy & Security rows) and a"
echo "different Application Support directory (separate queue database,"
echo "sessions, secrets)."
