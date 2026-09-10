#!/bin/bash
# audio-hal-watchdog — notice a wedged coreaudiod and keep the evidence.
#
# Why this exists (09 Sep 2026, third occurrence: 28 Aug, 03 Sep, 09 Sep): Apple's
# audio daemon deadlocks when Zoom activates its virtual "share computer sound"
# device while AirPods hold the HFP profile. From that moment every CoreAudio call
# from every app times out at 30s (MACH_RCV_TIMED_OUT 0x10004003). Recovery is a
# daemon restart, and since 09 Sep the app itself offers that on its "Audio
# stopped" card behind the password sheet. What no incident has ever produced is
# a spindump of coreaudiod AT THE MOMENT of the wedge, which is the one artefact
# that names the thread holding the lock and would settle whether this app was
# ever part of the deadlock. That is this script's job. It is developer
# diagnostics for this machine, not a product feature.
#
# Capture only, by default. It does not restart the daemon: the app's card does
# that with a person in the loop, and an automated privileged kill on a false
# positive would cut a live call for nothing. WATCHDOG_RESTART=1 turns the
# restart on for a machine nobody is sitting at.
#
# Probe: `say -a ?` asks the HAL for the output-device list. Healthy: returns in
# well under a second. Wedged: never returns (measured 09 Sep). Two failed probes
# PROBE_GAP seconds apart are required before acting, so a slow but live HAL (a
# Bluetooth renegotiation can take ~2s) is never reported.
#
# Privilege: exactly one sudoers line, one exact command with no wildcard
# (install.sh writes it):
#   <user> ALL=(root) NOPASSWD: /usr/sbin/spindump coreaudiod 3 -stdout
# The dump goes to stdout and is redirected by THIS script, as the user, so the
# rule cannot be used to write a file anywhere as root. `sample` needs no root
# for the user's own processes, so the app and Zoom are sampled without it.

set -u
STATE_DIR="${AUDIO_WATCHDOG_STATE:-$HOME/Library/Application Support/VoiceDispatch/audio-watchdog}"
LOG="$STATE_DIR/watchdog.log"
EVIDENCE_DIR="$STATE_DIR/incidents"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-8}"      # seconds a HAL query may take before it counts as hung
PROBE_GAP="${PROBE_GAP:-5}"              # seconds between the two confirming probes
DRY_RUN="${DRY_RUN:-0}"
RESTART="${WATCHDOG_RESTART:-0}"      # 1 = also killall coreaudiod (needs the second sudoers command)
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
notify "macOS audio is wedged" "Saving evidence. Use the app's Restart audio button, or: sudo killall coreaudiod"

{
  echo "captured $(ts)"; echo "coreaudiod pid: ${CA_PID:-none}"; echo
  ps -axo pid,stat,%cpu,etime,command | grep -E 'coreaudiod|Core Audio Driver|zoom|TranquilityApp' | grep -v grep
  echo; ls -la /Library/Audio/Plug-Ins/HAL/
} > "$INC/processes.txt" 2>&1
/usr/bin/log show --last 5m --style compact --predicate 'process == "coreaudiod" OR process == "zoom.us" OR process == "TranquilityApp" OR process == "bluetoothd"' > "$INC/unified-log-last-5m.txt" 2>&1 &
LOGPID=$!

# The user's own processes need no privilege to sample. Both sides of the
# deadlock, if this app is one of them.
for proc in TranquilityApp zoom.us; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    sample "$proc" 3 -file "$INC/$proc.sample.txt" >/dev/null 2>&1 && log "sampled $proc" || log "sample of $proc failed"
  fi
done

if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN: would spindump coreaudiod"; wait $LOGPID; exit 0; fi

if sudo -n /usr/sbin/spindump coreaudiod 3 -stdout > "$INC/coreaudiod.spindump.txt" 2>"$INC/spindump.err"; then
  log "spindump of coreaudiod saved ($(wc -c < "$INC/coreaudiod.spindump.txt") bytes)"
else
  log "spindump refused: run install.sh once to grant it (see spindump.err)"
fi

if [ "$RESTART" = "1" ]; then
  if sudo -n /usr/bin/killall coreaudiod 2>>"$LOG"; then
    log "killall coreaudiod sent (WATCHDOG_RESTART=1)"
    sleep 3
    if probe; then rm -f "$STATE_DIR/wedged"; log "RECOVERED: coreaudiod restarted (new pid $(pgrep -x coreaudiod | head -1))"; notify "Audio is back" "coreaudiod restarted."
    else log "still hung after restart"; fi
  else
    log "killall refused: install.sh --with-restart grants it"
  fi
fi
wait $LOGPID
