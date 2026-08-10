#!/bin/bash
#
# Does the courtesy check actually hear a person? Measured, not reasoned.
#
# Every unit test feeds `assess()` clean samples at effectively zero distance.
# `SFSpeechRecognizer` is tuned for someone speaking INTO a device, so the open
# question — the one the feature lives or dies on — is whether it hears a voice
# with real air in front of it. This plays stimuli through the speakers and
# listens on the real microphone, so the audio makes a genuine acoustic round
# trip through the same `Recorder.sampleRoom` path that ships.
#
# WHY IT RUNS THE APP AND NOT THE CLI: the microphone grant belongs to
# com.robertnowell.voice-dispatch. A CLI has no bundle identity of its own, so
# TCC attributes it to the terminal — which is denied on this machine, and which
# cannot be restarted while twenty sessions are live. The permission cannot move,
# so the harness does. `open -n` starts a second instance under the app's own
# identity; it enters CourtesyEval before AppKit exists (no status item, no
# hotkey, no race with the running instance), writes results, and exits.
#
# What we are looking for:
#   speech at any level  -> HOLD   (a miss here is the failure that matters)
#   noise / tone / quiet -> SPEAK  (a HOLD here means we mute on air conditioning)
#
# Usage: scripts/courtesy-eval.sh [repeats]      (default 2)
set -euo pipefail
cd "$(dirname "$0")/.."

REPEATS="${1:-2}"
WINDOW=4
WORK=$(mktemp -d)
APP=".build/debug/Tranquility Base.app"

# The deployed app runs its own courtesy checks, which open the microphone. Two
# processes contending for one input device does not produce a measurement — the
# 10 Aug run came back at roughly half the levels of every previous run for
# exactly this reason. So the running instance goes down for the duration and is
# brought back afterwards, on every exit path including Ctrl-C.
APP_WAS_RUNNING=no
if pgrep -f TranquilityApp >/dev/null; then
  APP_WAS_RUNNING=yes
  echo "→ stopping the running app so it cannot contend for the microphone"
  pkill -f TranquilityApp || true
  sleep 1
fi

restore_app() {
  rm -rf "$WORK"
  if [ "$APP_WAS_RUNNING" = yes ] && ! pgrep -f TranquilityApp >/dev/null; then
    echo "→ restarting the app"
    open -a "/Applications/Tranquility Base.app" 2>/dev/null || true
  fi
}
trap restore_app EXIT INT TERM

echo "→ building the app bundle"
scripts/bundle.sh >/dev/null
[ -d "$APP" ] || { echo "bundle.sh did not produce $APP" >&2; exit 1; }

echo "→ preparing stimuli"
SENTENCE="I think the retrieval numbers looked fine but we should double check \
the freshness window before anyone ships it on Monday morning"
say -o "$WORK/speech.aiff" "$SENTENCE"
# Speech with the gaps a real conversation has: the window can land in a pause,
# which is the second failure mode and needs its own row.
say -o "$WORK/paused.aiff" \
  "Right. [[slnc 1200]] So the thing is. [[slnc 1400]] I would just ship it."
python3 - "$WORK" <<'STIMULI'
import math, struct, sys, wave, random
d = sys.argv[1]
rate = 44100
def write(name, frames):
    with wave.open(f"{d}/{name}", "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767))
                               for s in frames))
random.seed(7)
write("noise.wav", [random.uniform(-1, 1) * 0.35 for _ in range(rate * 10)])
write("tone.wav", [math.sin(2 * math.pi * 440 * i / rate) * 0.35
                   for i in range(rate * 10)])
STIMULI

# label <TAB> output-volume <TAB> stimulus (empty = play nothing).
#
# Volume is the distance proxy, and an imperfect one: attenuation tracks
# distance, but a real talker two metres away also brings room reverb and
# off-axis directivity that a speaker at low volume does not. It moves the
# dominant variable — signal-to-noise at the mic — and holds the rest fixed,
# which is enough to find a cliff even if it cannot place one exactly. The human
# round at the end of the runbook is what covers the difference.
{
  printf 'quiet room\t20\t\n'
  printf 'speech near\t70\t%s\n'     "$WORK/speech.aiff"
  printf 'speech mid\t40\t%s\n'      "$WORK/speech.aiff"
  printf 'speech far\t20\t%s\n'      "$WORK/speech.aiff"
  printf 'speech very far\t10\t%s\n' "$WORK/speech.aiff"
  printf 'speech w pauses\t40\t%s\n' "$WORK/paused.aiff"
  printf 'broadband noise\t50\t%s\n' "$WORK/noise.wav"
  printf 'pure tone\t50\t%s\n'       "$WORK/tone.wav"
} > "$WORK/manifest.tsv"

: > "$WORK/all.tsv"
for r in $(seq 1 "$REPEATS"); do
  OUT="$WORK/round-$r.tsv"
  rm -f "$OUT"
  echo "→ round $r — 8 cases x ${WINDOW}s, about a minute. Sound will play."
  open -n -a "$PWD/$APP" --args --courtesy-eval "$WORK/manifest.tsv" "$OUT" "$WINDOW"

  # Poll rather than wait: `open` returns as soon as launchd has the process.
  for _ in $(seq 1 150); do [ -s "$OUT" ] && break; sleep 1; done
  if [ ! -s "$OUT" ]; then
    echo "✗ no results after 150s." >&2
    echo "  If macOS showed a microphone prompt, allow it and re-run." >&2
    exit 1
  fi
  echo "  --- how the APP saw it (mic grant, no speech grant) ---"
  grep '^#' "$OUT" | sed 's/^#/   /'
  grep -v '^#' "$OUT" >> "$WORK/all.tsv"
  grep -v '^#' "$OUT" | awk -F'\t' '{ printf "  %-17s vol %-3s %-5s level=%-8s words=%-3s %s\n",
                       $1, $2, $3, $4, $5, $6 }'

  # The same audio, assessed where speech recognition IS granted. This is the
  # only comparison that separates "the app cannot ask" from "the detector
  # cannot hear" — and only the second one would mean the approach is wrong.
  echo "  --- the SAME audio, recognised in the terminal (speech grant) ---"
  # Only the CAPTURED windows. The stimulus files live in the same directory
  # and assessing them measures our own synthesis, not the room.
  ./.build/debug/tbase courtesy-file "$WORK"/captured-*.wav 2>&1 | grep -v "^requesting"
done

echo
echo "→ tally (speech should HOLD; everything else should SPEAK)"
awk -F'\t' '
  { n[$1]++; if ($3 == "HOLD") h[$1]++ }
  END {
    for (k in n) {
      want = (k ~ /speech/) ? "HOLD" : "SPEAK"
      got  = (h[k] > n[k]/2) ? "HOLD" : "SPEAK"
      printf "  %-17s %d/%d HOLD   want %-5s  %s\n",
             k, h[k]+0, n[k], want, (want == got ? "ok" : "*** MISS ***")
    }
  }' "$WORK/all.tsv" | sort

cp "$WORK/all.tsv" ./courtesy-eval-results.tsv
echo
echo "Raw rows: ./courtesy-eval-results.tsv"
