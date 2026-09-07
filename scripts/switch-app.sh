#!/bin/bash
# Switch between the exact published app and the persistent Dev identity.
# Neither bundle is copied or re-signed here; the whole point is that their TCC
# identities remain stable.
#
# Usage: scripts/switch-app.sh prod|dev|status
set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/lib/app-process.sh"

SUPPORT="$HOME/Library/Application Support/VoiceDispatch"
PROD_APP="/Applications/Tranquility Base.app"
DEV_APP="/Applications/Tranquility Base Dev.app"
PROD_ID="com.robertnowell.voice-dispatch"
DEV_ID="com.robertnowell.voice-dispatch.dev"
TEAM_ID="FKE587SZ6H"
LOGIN_LABEL="$PROD_ID.selected"
LOGIN_PLIST="$HOME/Library/LaunchAgents/$LOGIN_LABEL.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$PROD_ID.plist"
DB="$SUPPORT/queue.sqlite"
CHANNEL_FILE="$SUPPORT/selected-channel"

channel="${1:-status}"
case "$channel" in
  prod) TARGET="$PROD_APP"; TARGET_ID="$PROD_ID" ;;
  dev) TARGET="$DEV_APP"; TARGET_ID="$DEV_ID" ;;
  status)
    if app_at_path_running "$PROD_APP"; then echo "prod"
    elif app_at_path_running "$DEV_APP"; then echo "dev"
    else echo "stopped"
    fi
    exit 0 ;;
  *) echo "usage: scripts/switch-app.sh prod|dev|status" >&2; exit 2 ;;
esac

fail() { echo "✗ $*" >&2; exit 1; }
read_target() { /usr/libexec/PlistBuddy -c "Print :$1" "$TARGET/Contents/Info.plist" 2>/dev/null; }
[ -d "$TARGET" ] || fail "$TARGET is not installed"
[ "$(read_target CFBundleIdentifier)" = "$TARGET_ID" ] || fail "$TARGET has the wrong bundle id"
codesign --verify --deep --strict "$TARGET" 2>/dev/null || fail "$TARGET has an invalid signature"
if [ "$channel" = "prod" ]; then
  TARGET_SIGNING=$(codesign -dv --verbose=4 "$TARGET" 2>&1 || true)
  case "$TARGET_SIGNING" in
    *"Authority=Developer ID Application: Robert Nowell ($TEAM_ID)"*"TeamIdentifier=$TEAM_ID"*) ;;
    *) fail "Prod is not the published Developer ID build; install the release DMG first" ;;
  esac
  TARGET_ASSESS=$(/usr/sbin/spctl --assess --type execute -vv "$TARGET" 2>&1 || true)
  case "$TARGET_ASSESS" in
    *": accepted"*"source=Notarized Developer ID"*) ;;
    *) fail "Prod is not an accepted notarized release; install the release DMG first" ;;
  esac
else
  [ "$(read_target TBAppChannel)" = "development" ] || fail "Dev has the wrong channel stamp"
  [ "$(read_target TBUpdatesEnabled)" = "false" ] || fail "Dev is allowed to consume updates"
  TARGET_SIGNING=$(codesign -dv --verbose=2 "$TARGET" 2>&1 || true)
  case "$TARGET_SIGNING" in
    *$'\nAuthority='*|Authority=*) ;;
    *) fail "Dev is ad-hoc signed; its permissions would not survive a rebuild" ;;
  esac
fi

# A merge deploy and a lane switch both stop and start the same singleton. Use
# the deployer's existing lock so they can never interleave.
LOCKDIR="/tmp/tb-relaunch.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  HOLDER=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
  if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then
    fail "another app mutation (pid $HOLDER) is in progress"
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || fail "lost the app-mutation lock race"
fi
echo $$ > "$LOCKDIR/pid"

ACTIVE_BEFORE=""
app_at_path_running "$PROD_APP" && ACTIVE_BEFORE="$PROD_APP"
app_at_path_running "$DEV_APP" && ACTIVE_BEFORE="$DEV_APP"
SWITCHED=0

write_login_item() {
  local path="$1"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$LOGIN_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LOGIN_LABEL</string>
  <key>ProgramArguments</key><array><string>$path/Contents/MacOS/TranquilityApp</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
}

cleanup() {
  rm -rf "$LOCKDIR"
  if [ "$SWITCHED" -eq 0 ] && [ -n "$ACTIVE_BEFORE" ] \
     && [ -d "$ACTIVE_BEFORE" ]; then
    # "An app is running" is not rollback: after a late singleton failure it
    # may be the newly selected lane. Remove that failed target, then restore
    # the exact path and login item the user had before the switch.
    if [ "$TARGET" != "$ACTIVE_BEFORE" ] && app_at_path_running "$TARGET"; then
      app_stop_path "$TARGET"
    fi
    if app_at_path_running "$ACTIVE_BEFORE"; then return; fi
    echo "→ switch failed; restoring the previous lane" >&2
    write_login_item "$ACTIVE_BEFORE"
    launchctl bootout "gui/$UID/$LOGIN_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$LOGIN_PLIST" 2>/dev/null \
      || open "$ACTIVE_BEFORE" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM PIPE

# Refuse a target older than the schema already on disk. Before a newer target
# advances it, take a transactionally consistent backup so an intentional
# rollback has a real recovery point rather than a copied WAL fragment.
TARGET_SCHEMA=$(read_target TBDatabaseSchemaVersion 2>/dev/null || echo 18)
CURRENT_SCHEMA=0
if [ -f "$DB" ]; then
  CURRENT_SCHEMA=$(sqlite3 "$DB" "select identifier from grdb_migrations;" 2>/dev/null \
    | sed -nE 's/^v([0-9]+)_.*/\1/p' | sort -n | tail -1 || true)
  CURRENT_SCHEMA="${CURRENT_SCHEMA:-0}"
fi
[ "$CURRENT_SCHEMA" -le "$TARGET_SCHEMA" ] \
  || fail "database schema v$CURRENT_SCHEMA is newer than $channel can read (v$TARGET_SCHEMA)"
if [ -f "$DB" ] && [ "$TARGET_SCHEMA" -gt "$CURRENT_SCHEMA" ]; then
  BACKUP_DIR="$SUPPORT/schema-backups"
  mkdir -p "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/before-v${TARGET_SCHEMA}-$(date -u +%Y%m%dT%H%M%SZ).sqlite"
  sqlite3 "$DB" ".backup '$BACKUP'" || fail "could not create the pre-migration backup"
  chmod 600 "$BACKUP"
  echo "→ schema backup: $BACKUP"
fi

# Same never-kill-a-capture rule as relaunch.sh. The marker heartbeats while
# recording; stale files do not wedge switching forever.
MARKER="$SUPPORT/capturing"
waited=0
while [ -f "$MARKER" ]; do
  stamped=$(cat "$MARKER" 2>/dev/null || echo 0)
  case "$stamped" in ''|*[!0-9]*) stamped=0 ;; esac
  age=$(( $(date +%s) - stamped ))
  if [ "$stamped" -eq 0 ] || [ "$age" -ge 20 ]; then break; fi
  [ "$waited" -lt 120 ] || fail "microphone is still open; leaving the current lane running"
  [ "$waited" -ne 0 ] || echo "→ microphone is open; waiting before switching"
  sleep 2
  waited=$((waited + 2))
done

app_stop
write_login_item "$TARGET"
# Remove the old production-only login item. Two launch items would make the
# selected lane nondeterministic at the next login.
launchctl bootout "gui/$UID/$PROD_ID" 2>/dev/null || true
rm -f "$LEGACY_PLIST"
launchctl bootout "gui/$UID/$LOGIN_LABEL" 2>/dev/null || true
if ! launchctl bootstrap "gui/$UID" "$LOGIN_PLIST" 2>/dev/null; then
  open "$TARGET"
fi

started=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if app_at_path_running "$TARGET"; then started=1; break; fi
  sleep 0.5
done
[ "$started" -eq 1 ] || fail "$channel did not stay running"
[ "$(app_count)" -eq 1 ] || fail "more than one product lane is running"
mkdir -p "$SUPPORT"
printf '%s\n' "$channel" > "$CHANNEL_FILE"
chmod 600 "$CHANNEL_FILE"
SWITCHED=1
echo "✓ switched to $channel: $TARGET"
