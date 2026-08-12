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
# never contain, and which matches both the installed copy and a worktree build:
#
#   /Applications/Tranquility Base.app/Contents/MacOS/TranquilityApp
#   /private/tmp/tb-clean/.build/debug/Tranquility Base.app/Contents/MacOS/TranquilityApp
#
# Defined once and sourced, rather than pasted into both scripts: the pose
# fixture in StatusHUD.swift is currently living proof of what happens when the
# same literal is maintained in two places — one copy was upgraded and the other
# still holds the shape it was upgraded away from.
APP_PROC_PATTERN="Tranquility Base.app/Contents/MacOS/TranquilityApp"

# True when a real app process is up. Never true for a build.
app_running() {
  pgrep -f "$APP_PROC_PATTERN" >/dev/null 2>&1
}

# How many are up. Two instances fight over one global hotkey.
app_count() {
  pgrep -f "$APP_PROC_PATTERN" 2>/dev/null | wc -l | tr -d ' '
}

# Stop it if it is up. Safe to call when nothing is running.
app_stop() {
  if app_running; then
    echo "→ stopping the running instance"
    pkill -f "$APP_PROC_PATTERN" || true
    sleep 1
  fi
}
