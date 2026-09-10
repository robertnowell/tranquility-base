#!/bin/bash
# Install the audio HAL watchdog: a launchd agent every 20s plus the ONE sudo rule
# it needs to capture a spindump of coreaudiod. Run as yourself; it asks for your
# password once, for the sudoers file.
#
#   install.sh                 capture only (default)
#   install.sh --with-restart  also allow `killall coreaudiod` for WATCHDOG_RESTART=1
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="$(id -un)"
STATE="$HOME/Library/Application Support/VoiceDispatch/audio-watchdog"
mkdir -p "$STATE"
WITH_RESTART=0; [ "${1:-}" = "--with-restart" ] && WITH_RESTART=1

# 1. sudoers: exact commands, no wildcards. visudo -c validates before it lands.
#    Skipped, and no password asked, when the rule is already in force: a
#    re-run to update the script must not cost a password.
CMDS="/usr/sbin/spindump coreaudiod 3 -stdout"
[ "$WITH_RESTART" = 1 ] && CMDS="$CMDS, /usr/bin/killall coreaudiod"
granted() {
  # Captured to a file, never piped: `| head` closes the pipe early, spindump
  # takes SIGPIPE, and pipefail reports the rule as broken when it works.
  local out; out=$(mktemp)
  sudo -n /usr/sbin/spindump coreaudiod 1 -stdout > "$out" 2>/dev/null
  local ok=1; [ -s "$out" ] && ok=0
  rm -f "$out"; return $ok
}
if [ "$WITH_RESTART" = 0 ] && granted; then
  echo "sudoers: already granted, leaving /etc/sudoers.d/audio-hal-watchdog as it is"
else
  SUDOERS_TMP=$(mktemp)
  cat > "$SUDOERS_TMP" <<S
# audio-hal-watchdog (tranquility-base/tools/audio-hal-watchdog): capture a spindump of a
# wedged coreaudiod. Exact commands only; the dump goes to stdout and is redirected as the user.
$USER_NAME ALL=(root) NOPASSWD: $CMDS
S
  sudo visudo -c -f "$SUDOERS_TMP" >/dev/null
  sudo install -o root -g wheel -m 0440 "$SUDOERS_TMP" /etc/sudoers.d/audio-hal-watchdog
  rm -f "$SUDOERS_TMP"
  echo "sudoers: /etc/sudoers.d/audio-hal-watchdog installed ($CMDS)"
  # Prove the rule works on a healthy daemon: one second of stacks to a file.
  if granted; then echo "sudoers: passwordless spindump verified"
  else echo "sudoers rule did not take"; exit 1; fi
fi

# 2. the script itself, copied to the state directory. launchd runs it from
#    there, so the checkout this was installed from can be a worktree that
#    is removed tomorrow, or a /private/tmp build that is reaped next week,
#    and the agent keeps working. Re-run install.sh to update the copy.
install -m 0755 "$HERE/watchdog.sh" "$STATE/watchdog.sh"
echo "script:  $STATE/watchdog.sh"

# 3. launchd agent
PLIST="$HOME/Library/LaunchAgents/com.tranquilitybase.audio-hal-watchdog.plist"
sed -e "s|__WATCHDOG__|$STATE/watchdog.sh|g" -e "s|__HOME__|$HOME|g" \
  "$HERE/com.tranquilitybase.audio-hal-watchdog.plist" > "$PLIST"
launchctl bootout "gui/$(id -u)/com.tranquilitybase.audio-hal-watchdog" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "launchd: com.tranquilitybase.audio-hal-watchdog loaded (every 20s, capture only)"
echo "log:     $STATE/watchdog.log"
echo "test:    DRY_RUN=1 PROBE_TIMEOUT=0 bash \"$STATE/watchdog.sh\" && tail -3 \"$STATE/watchdog.log\""
echo "remove:  launchctl bootout gui/$(id -u)/com.tranquilitybase.audio-hal-watchdog; sudo rm /etc/sudoers.d/audio-hal-watchdog"
