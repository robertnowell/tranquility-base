#!/bin/bash
# audio-hal-watchdog — notice a wedged coreaudiod, keep the evidence, bring audio back.
#
# Why this exists (09 Sep 2026, third occurrence: 28 Aug, 03 Sep, 09 Sep): Apple's
# audio daemon deadlocks when Zoom activates its virtual "share computer sound"
# device while AirPods hold the HFP profile. From that moment every CoreAudio call
# from every app times out at 30s (MACH_RCV_TIMED_OUT 0x10004003), Zoom shows no
# audio devices, Tranquility Base loses mic and voice, and nothing recovers on its
# own. The fix is a one-second restart of coreaudiod; without this script it took
# a reboot mid-meeting. The daemon is Apple's, so we cannot stop the deadlock; we
# can make it cost ten seconds instead of ten minutes, and keep the spindump that
# says who held the lock, which no incident so far has captured.
#
# Probe: `say -a ?` asks the HAL for the output-device list. Healthy: returns in
# well under a second. Wedged: never returns (measured 09 Sep: hung indefinitely).
# Two failed probes PROBE_GAP seconds apart are required before acting, so a slow
# but live HAL (a Bluetooth renegotiation can take ~2s) is never restarted.
#
# Requires, for the act step only, a sudoers entry (install.sh writes it):
#   <user> ALL=(root) NOPASSWD: /usr/sbin/spindump coreaudiod *, /usr/bin/killall coreaudiod
# Without it the script still detects and records, and tells you what to run.

set -u
STATE_DIR="${AUDIO_WATCHDOG_STATE:-$HOME/Library/Application Support/VoiceDispatch/audio-watchdog}"
LOG="$STATE_DIR/watchdog.log"
EVIDENCE_DIR="$STATE_DIR/incidents"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"      # seconds a HAL query may take before it counts as hung
PROBE_GAP="${PROBE_GAP:-5}"              # seconds between the two confirming probes
DRY_RUN="${DRY_RUN:-0}"
mkdir -p "$STATE_DIR" "$EVIDENCE_DIR"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts)  $*" >> "$LOG"; }

# 0 = HAL answered, 1 = HAL hung past PROBE_TIMEOUT
probe() {
  local out; out=$(mktemp)
  say -a '?' > "$out" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null   # so a kill -9 below prints no job-control noise
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$PROBE_TIMEOUT" ]; then
      kill -9 "$pid" 2>/dev/null; rm -f "$out"; return 1
    fi
    sleep 1; waited=$((waited+1))
  done
  rm -f "$out"; return 0
}

notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

if probe; then
  # Healthy. Keep the log quiet: one line per state change only.
  if [ -f "$STATE_DIR/wedged" ]; then rm -f "$STATE_DIR/wedged"; log "recovered: HAL answering again"; fi
  exit 0
fi

log "probe 1 hung >${PROBE_TIMEOUT}s; confirming in ${PROBE_GAP}s"
sleep "$PROBE_GAP"
if probe; then log "probe 2 answered; false alarm, no action"; exit 0; fi

# Confirmed wedge.
touch "$STATE_DIR/wedged"
STAMP=$(date +%Y%m%d-%H%M%S)
INC="$EVIDENCE_DIR/$STAMP"; mkdir -p "$INC"
CA_PID=$(pgrep -x coreaudiod | head -1)
log "WEDGED: coreaudiod pid=${CA_PID:-?} not answering; evidence -> $INC"
notify "macOS audio is wedged" "coreaudiod stopped answering. Every app's audio is affected. Restarting it now."

# Evidence first, restart second: the spindump is the only artefact that names the
# thread holding the lock, and it is gone the moment the daemon is killed.
{
  echo "captured $(ts)"; echo "coreaudiod pid: ${CA_PID:-none}"; echo
  ps -axo pid,stat,%cpu,etime,command | grep -E 'coreaudiod|Core Audio Driver|zoom|TranquilityApp' | grep -v grep
  echo; ls -la /Library/Audio/Plug-Ins/HAL/
} > "$INC/processes.txt" 2>&1
/usr/bin/log show --last 5m --style compact --predicate 'process == "coreaudiod" OR process == "zoom.us" OR process == "TranquilityApp" OR process == "bluetoothd"' > "$INC/unified-log-last-5m.txt" 2>&1 &
LOGPID=$!

if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN: would spindump + killall coreaudiod"; wait $LOGPID; exit 0; fi

if sudo -n true 2>/dev/null; then
  sudo -n /usr/sbin/spindump coreaudiod 3 -file "$INC/coreaudiod.spindump.txt" >/dev/null 2>&1 \
    && log "spindump saved" || log "spindump failed (sudoers missing the spindump rule?)"
  if sudo -n /usr/bin/killall coreaudiod 2>>"$LOG"; then
    log "killall coreaudiod sent"
  else
    log "killall refused: run  sudo killall coreaudiod  by hand"; notify "Audio still wedged" "Run: sudo killall coreaudiod"; wait $LOGPID; exit 2
  fi
else
  log "no passwordless sudo; cannot act. Run:  sudo killall coreaudiod   (install.sh grants this)"
  notify "Audio is wedged, cannot self-heal" "Run in Terminal: sudo killall coreaudiod"
  wait $LOGPID; exit 2
fi

# Verify.
sleep 3
if probe; then
  rm -f "$STATE_DIR/wedged"
  log "RECOVERED: coreaudiod restarted (new pid $(pgrep -x coreaudiod | head -1)); HAL answering"
  notify "Audio is back" "coreaudiod restarted. Reconnect AirPods if they dropped."
else
  log "still hung after restart; a second killall or a reboot is next"
  notify "Audio still wedged after restart" "Try: sudo killall coreaudiod again, then reboot"
fi
wait $LOGPID
