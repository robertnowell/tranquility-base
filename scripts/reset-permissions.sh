#!/bin/bash
#
# Clear every TCC grant for this app, so the next grant binds to the current code
# signature.
#
# WHEN YOU NEED THIS
#
# After the signing identity changes — which is any time you switch from ad-hoc to a
# real certificate, regenerate the certificate, or (before scripts/make-signing-identity.sh
# existed) simply rebuilt. Symptom: the Privacy & Security pane lists Voice Dispatch
# with its switch ON, and the app's own checklist still says "not granted".
#
# Toggling the switch does not fix that, and neither does removing the row with "−":
# the stored grant is keyed to a code identity that no longer exists, and macOS gives
# you no way to re-point it. Deleting the grant and asking again is the only route.
#
# The app must not be running: TCC evaluates authorisation per process at launch, so a
# live instance would keep its stale answer and you would conclude this did not work.

set -uo pipefail

BUNDLE_ID="com.robertnowell.voice-dispatch"

if pgrep -f VoiceDispatchApp >/dev/null 2>&1; then
  echo "quitting the app first (its authorisation is decided at launch)"
  pkill -f VoiceDispatchApp || true
  sleep 2
fi

# ListenEvent is Input Monitoring; Accessibility covers the event tap and typing at
# the cursor. Microphone and AppleEvents are included so one command puts the app back
# to a known-clean state rather than a partly-granted one that is harder to reason about.
for service in Accessibility ListenEvent Microphone AppleEvents; do
  out=$(tccutil reset "$service" "$BUNDLE_ID" 2>&1) && echo "  reset $service" \
    || echo "  reset $service — $out"
done

echo
echo "All grants cleared. Now:"
echo "  1. open \".build/debug/Voice Dispatch.app\""
echo "  2. click Grant on each row in the checklist — Grant is what makes macOS ASK,"
echo "     and an app that has never asked is not listed in the Privacy pane at all,"
echo "     so there is nothing to switch on until you do."
echo "  3. relaunch once after granting Accessibility: AXIsProcessTrusted() is"
echo "     evaluated when the process starts, so a running instance cannot see it."
