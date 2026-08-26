#!/bin/bash
#
# Clear every TCC grant for this app, so the next grant binds to the current code
# signature.
#
# WHEN YOU NEED THIS
#
# After the signing identity changes — which is any time you switch from ad-hoc to a
# real certificate, regenerate the certificate, or (before scripts/make-signing-identity.sh
# existed) simply rebuilt. Symptom: the Privacy & Security pane lists Tranquility Base
# with its switch ON, and the app's own checklist still says "not granted".
#
# Toggling the switch does not fix that, and neither does removing the row with "−":
# the stored grant is keyed to a code identity that no longer exists, and macOS gives
# you no way to re-point it. Deleting the grant and asking again is the only route.
#
# The app must not be running: TCC evaluates authorisation per process at launch, so a
# live instance would keep its stale answer and you would conclude this did not work.

set -uo pipefail

# Deliberately still `voice-dispatch` after the rename to Tranquility Base. TCC keys
# grants to the bundle identifier, so changing this string would not rename anything —
# it would make macOS treat the app as one it has never seen and silently void every
# permission. It must track bundle.sh's BUNDLE_ID, whatever that says, not the product
# name.
BUNDLE_ID="com.robertnowell.voice-dispatch"

# Matches the executable name, which the rename DID change. `pkill -f VoiceDispatchApp`
# quietly matched nothing after the rename, leaving the app running while the script
# reported success — and this script's whole premise is that it is not.
if pgrep -f TranquilityApp >/dev/null 2>&1; then
  echo "quitting the app first (its authorisation is decided at launch)"
  pkill -f TranquilityApp || true
  sleep 2
fi

# ListenEvent is Input Monitoring; Accessibility covers the event tap and typing at
# the cursor. Microphone and AppleEvents are included so one command puts the app back
# to a known-clean state rather than a partly-granted one that is harder to reason about.
#
# SpeechRecognition was missing from this list until 26 Aug, and that omission has a
# crash attached to it. `Permissions.request(.speechRecognition)` is reachable from
# exactly one place — the Grant button on the Speech row, which is hidden once the
# permission is granted — so an incomplete reset here meant the line was never run
# again on this machine after the first time. It shipped a SIGTRAP to the first
# external user (incident 51344D00). A reset script that resets MOST of the state
# leaves precisely the paths nobody exercises, which are the paths that break.
for service in Accessibility ListenEvent Microphone AppleEvents SpeechRecognition; do
  out=$(tccutil reset "$service" "$BUNDLE_ID" 2>&1) && echo "  reset $service" \
    || echo "  reset $service — $out"
done

echo
echo "All grants cleared. Now:"
echo "  1. open \".build/debug/Tranquility Base.app\""
echo "  2. click Grant on each row in the checklist — Grant is what makes macOS ASK,"
echo "     and an app that has never asked is not listed in the Privacy pane at all,"
echo "     so there is nothing to switch on until you do."
echo "  3. work down the whole list before restarting. The checklist tracks which"
echo "     rows are granted-but-not-yet-usable and offers ONE restart at the end;"
echo "     a restart per permission means three of them, and the count survives"
echo "     because it is read from macOS, not stored by the app."
