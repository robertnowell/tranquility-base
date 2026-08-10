#!/bin/bash
#
# Does the courtesy check actually hear a person? Measured, not reasoned.
#
# Every test up to now fed `assess()` clean samples at effectively zero
# distance. `SFSpeechRecognizer` is tuned for someone speaking INTO a device,
# so the open question — the one the feature lives or dies on — is whether it
# hears a voice with real air in front of it. This answers that by playing
# stimuli through the speakers and listening on the real microphone, so the
# audio makes a genuine acoustic round trip.
#
# Output volume is the distance proxy. It is not a perfect one: attenuation
# tracks distance, but a real talker two metres away also brings room reverb
# and off-axis directivity that a speaker at low volume does not. It moves the
# dominant variable (signal-to-noise at the mic) and leaves the others fixed,
# which is enough to find a cliff even if it cannot place it exactly.
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
TB=".build/debug/tbase"
WORK=$(mktemp -d)

# The user's volume is theirs. Put it back on every exit path, including Ctrl-C.
ORIGINAL_VOLUME=$(osascript -e 'output volume of (get volume settings)')
cleanup() {
  osascript -e "set volume output volume $ORIGINAL_VOLUME" || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ -x "$TB" ] || { echo "build first: swift build --product tbase" >&2; exit 1; }

echo "→ preparing stimuli in $WORK"
SENTENCE="I think the retrieval numbers looked fine but we should double check the \
freshness window before anyone ships it on Monday morning"
say -o "$WORK/speech.aiff" "$SENTENCE"
# Speech with the gaps a real conversation has: the window can land in a pause,
# which is the second failure mode and needs its own row.
say -o "$WORK/paused.aiff" "Right. [[slnc 1200]] So the thing is. [[slnc 1400]] I would just ship it."
python3 - "$WORK" <<'PY'
import math, struct, sys, wave, random
d = sys.argv[1]
rate = 44100
def write(name, frames):
    with wave.open(f"{d}/{name}", "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in frames))
random.seed(7)
write("noise.wav", [random.uniform(-1, 1) * 0.35 for _ in range(rate * 8)])
write("tone.wav", [math.sin(2 * math.pi * 440 * i / rate) * 0.35 for i in range(rate * 8)])
PY

run_case() {
  local label="$1" volume="$2" stimulus="${3:-}"
  osascript -e "set volume output volume $volume"
  local pid=""
  if [ -n "$stimulus" ]; then
    afplay "$stimulus" & pid=$!
    sleep 0.4           # let the sound actually be in the air before we listen
  fi
  local out
  out=$("$TB" courtesy-live "$WINDOW" 2>&1 | tail -1)
  [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
  printf '  %-22s vol %-3s  %s\n' "$label" "$volume" "$out"
  printf '%s\t%s\t%s\n' "$label" "$volume" "$out" >> "$WORK/results.tsv"
}

echo "→ window ${WINDOW}s, ${REPEATS} repeat(s). Restoring volume to $ORIGINAL_VOLUME at exit."
echo
for r in $(seq 1 "$REPEATS"); do
  echo "round $r"
  run_case "quiet room"        20 ""
  run_case "speech near"       70 "$WORK/speech.aiff"
  run_case "speech mid"        40 "$WORK/speech.aiff"
  run_case "speech far"        20 "$WORK/speech.aiff"
  run_case "speech very far"   10 "$WORK/speech.aiff"
  run_case "speech w/ pauses"  40 "$WORK/paused.aiff"
  run_case "broadband noise"   50 "$WORK/noise.wav"
  run_case "pure tone"         50 "$WORK/tone.wav"
  echo
done

echo "→ tally (what SHOULD happen: speech=HOLD, everything else=SPEAK)"
awk -F'\t' '
  { n[$1]++; if ($3 ~ /^HOLD/) h[$1]++ }
  END {
    for (k in n) {
      want = (k ~ /speech/) ? "HOLD" : "SPEAK"
      got  = (h[k] > n[k]/2) ? "HOLD" : "SPEAK"
      printf "  %-22s %d/%d HOLD   want %-5s  %s\n", k, h[k]+0, n[k], want, (want==got ? "ok" : "*** MISS ***")
    }
  }' "$WORK/results.tsv" | sort

echo
echo "Raw rows: $WORK/results.tsv (deleted on exit — copy now if you want them)"
cp "$WORK/results.tsv" ./courtesy-eval-results.tsv 2>/dev/null && \
  echo "Copied to ./courtesy-eval-results.tsv"
