#!/bin/bash
# Install the audio HAL watchdog: a launchd agent every 20s plus the two sudo rules it
# needs to act. Run as yourself; it asks for your password once, for the sudoers file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="$(id -un)"
STATE="$HOME/Library/Application Support/VoiceDispatch/audio-watchdog"
mkdir -p "$STATE"

# 1. sudoers: exactly two commands, nothing else. visudo -c validates before it lands.
SUDOERS_TMP=$(mktemp)
cat > "$SUDOERS_TMP" <<S
# audio-hal-watchdog (tranquility-base/tools/audio-hal-watchdog): restart a wedged coreaudiod
# and capture its spindump first. Nothing else.
$USER_NAME ALL=(root) NOPASSWD: /usr/sbin/spindump coreaudiod *, /usr/bin/killall coreaudiod
S
sudo visudo -c -f "$SUDOERS_TMP" >/dev/null
sudo install -o root -g wheel -m 0440 "$SUDOERS_TMP" /etc/sudoers.d/audio-hal-watchdog
rm -f "$SUDOERS_TMP"
echo "sudoers: /etc/sudoers.d/audio-hal-watchdog installed"
sudo -n /usr/bin/killall -0 coreaudiod 2>/dev/null && echo "sudoers: passwordless killall verified" || { echo "sudoers rule did not take"; exit 1; }

# 2. launchd agent
PLIST="$HOME/Library/LaunchAgents/com.tranquilitybase.audio-hal-watchdog.plist"
sed -e "s|__WATCHDOG__|$HERE/watchdog.sh|g" -e "s|__HOME__|$HOME|g" \
  "$HERE/com.tranquilitybase.audio-hal-watchdog.plist" > "$PLIST"
launchctl bootout "gui/$(id -u)/com.tranquilitybase.audio-hal-watchdog" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "launchd: com.tranquilitybase.audio-hal-watchdog loaded (every 20s)"
echo "log:     $STATE/watchdog.log"
echo "test:    DRY_RUN=1 PROBE_TIMEOUT=0 bash $HERE/watchdog.sh && tail -3 \"$STATE/watchdog.log\""
