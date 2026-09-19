#!/bin/bash
#
# One definition of "the running app", because two scripts were matching it by a
# name that also matches the compiler.
#
# `pkill -f TranquilityApp` matches `swift build --product TranquilityApp`. Both
# relaunch.sh and install.sh stop the app that way, and relaunch.sh orders its
# kill after its own build deliberately — which protects the first relaunch and
# does nothing for a second one, or for a parallel session building while you
# install. Observed rather than theorised: `bundle.sh: line 25: Terminated: 15`,
# one relaunch producing no app.
#
# The pattern below is the bundle's executable PATH, which a build command can
# never contain, and which matches both persistent product lanes plus their
# worktree builds:
#
#   /Applications/Tranquility Base.app/Contents/MacOS/TranquilityApp
#   /Applications/Tranquility Base Dev.app/Contents/MacOS/TranquilityApp
#   /private/tmp/tb-clean/.build/bundle/debug/Tranquility Base.app/Contents/MacOS/TranquilityApp
#
# Defined once and sourced, rather than pasted into both scripts: the pose
# fixture in StatusHUD.swift is currently living proof of what happens when the
# same literal is maintained in two places — one copy was upgraded and the other
# still holds the shape it was upgraded away from.
APP_PROC_PATTERN="Tranquility Base( Dev)?[.]app/Contents/MacOS/TranquilityApp"

# True when a real app process is up. Never true for a build.
app_running() {
  pgrep -f "$APP_PROC_PATTERN" >/dev/null 2>&1
}

# How many are up. Two instances fight over one global hotkey.
app_count() {
  pgrep -f "$APP_PROC_PATTERN" 2>/dev/null | wc -l | tr -d ' '
}

# True only for the bundle at an exact path. The broad helpers arbitrate both
# lanes; deploy verification must prove the lane it just launched, not merely
# notice that the other one is still alive.
app_at_path_running() {
  pgrep -f "$1/Contents/MacOS/TranquilityApp" >/dev/null 2>&1
}

# ── Never kill a live microphone ─────────────────────────────────────────────
#
# This lives HERE, on the kill itself, and not in the one script that happened
# to report the bug. Four scripts stop the app — relaunch.sh, install.sh,
# install-dev.sh, switch-app.sh — and until now exactly one of them asked
# whether anybody was mid-sentence. A rule enforced by whoever remembers it is
# not a rule; a rule enforced at the single line that does the killing is.
#
# The recorder holds the whole utterance in memory and flushes once at key-up,
# so killing mid-sentence does not lose a file, it loses the words. Ruled
# 10 Sep ("an open microphone is a promise"); this is the deploy half of it.
#
# The marker is written by Recorder.start, re-stamped every
# CaptureMarker.heartbeat seconds while the microphone is open, and cleared by
# stop/abandon. Its age therefore means "silence from the writer", not "length
# of the utterance" — reading it as the latter, at 180s, is what let a script
# destroy a live four-minute capture on 10 Aug. STALE_AFTER mirrors
# CaptureMarker.staleAfter, which bash cannot read. Change both or neither.
TB_CAPTURE_MARKER="$HOME/Library/Application Support/VoiceDispatch/capturing"
TB_MIC_STALE_AFTER=20
TB_MIC_GIVE_UP_AFTER=120

# Wait for the microphone to close, or refuse to proceed.
#
# `$1` names the moment, so a log line says which caller is waiting. Refusing
# is the safe failure everywhere this is called: the app keeps running the
# build it is already running, which is what it was doing a second ago. Losing
# the utterance is not recoverable; being one commit behind for another minute
# is. TB_KILL_ANYWAY=1 overrides, for a wedged marker no heartbeat is clearing.
wait_for_microphone() {
  local when="${1:-stopping the app}" waited=0 started age
  [ "${TB_KILL_ANYWAY:-0}" = "1" ] && return 0
  while [ -f "$TB_CAPTURE_MARKER" ]; do
    started=$(cat "$TB_CAPTURE_MARKER" 2>/dev/null || echo 0)
    case "$started" in ''|*[!0-9]*) started=0 ;; esac
    age=$(( $(date +%s) - started ))
    if [ "$started" -eq 0 ] || [ "$age" -ge "$TB_MIC_STALE_AFTER" ]; then
      echo "→ ignoring a stale capture marker (${age}s old)"
      return 0
    fi
    if [ "$waited" -ge "$TB_MIC_GIVE_UP_AFTER" ]; then
      echo "✗ an utterance is still in flight after ${waited}s (${when}) — not stopping the app." >&2
      echo "  It stays on its current build. Run this again when you're done," >&2
      echo "  or TB_KILL_ANYWAY=1 if the marker is wedged." >&2
      # An ongoing utterance is a safe deferral, not evidence that the source
      # failed. Let the durable worker retry after it ends without holding the
      # source indefinitely. Manual callers retain their existing failure code.
      if [ "${TB_DEPLOY_AUTOMATIC:-0}" = "1" ]; then exit 75; fi
      exit 1
    fi
    [ "$waited" -eq 0 ] && echo "→ an utterance is in flight — mic open, transcribing, or delivering (${when}); waiting for it to land"
    sleep 2
    waited=$(( waited + 2 ))
  done
  return 0
}

app_stop_path() {
  if app_at_path_running "$1"; then
    wait_for_microphone "stopping $1"
    if declare -F tb_before_app_stop >/dev/null; then tb_before_app_stop; fi
    echo "→ stopping $1"
    pkill -f "$1/Contents/MacOS/TranquilityApp" || true
    sleep 1
  fi
}

# Stop it if it is up. Safe to call when nothing is running.
#
# The microphone is asked INSIDE the `app_running` branch on purpose: a call
# that has nothing to kill must stay a no-op, and waiting two minutes for a
# capture before declining to kill a process that does not exist would turn
# every belt-and-braces call site into a hang.
app_stop() {
  if app_running; then
    wait_for_microphone "stopping the running instance"
    if declare -F tb_before_app_stop >/dev/null; then tb_before_app_stop; fi
    echo "→ stopping the running instance"
    pkill -f "$APP_PROC_PATTERN" || true
    sleep 1
  fi
}
