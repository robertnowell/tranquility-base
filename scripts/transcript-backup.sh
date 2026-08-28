#!/bin/bash
#
# Keep a cumulative copy of every Claude Code transcript.
#
# Why this exists: a forked transcript loses nothing — the bytes stay on disk,
# which is the only reason 17,451 stranded messages were recoverable on 27 Aug.
# What actually destroys history is DELETION, and on this machine there were no
# backups of any kind and an unset `cleanupPeriodDays`, meaning a retention
# default nobody chose was the only thing deciding how long conversations lived.
#
# The design leans on one property: transcripts are APPEND-ONLY, so files grow
# and never shrink in normal operation.
#
#   * no --delete   a transcript removed by Claude Code's cleanup stays here
#                   forever. The mirror is strictly cumulative.
#   * shrink guard  the one case that assumption could fail. If a source file is
#                   SMALLER than the copy already held, something rewrote or
#                   truncated it, and syncing would overwrite a long file with a
#                   short one — destroying exactly what this protects. Those are
#                   set aside under versions/<date> BEFORE the sync.
#
# The shrink check is done by size rather than by rsync's --backup, which was
# the first attempt and was wrong: --backup sets the old copy aside on ANY
# change, so an append-only archive would accumulate a full duplicate of every
# active transcript on every run. Caught on the second run, when this session's
# own 6MB transcript was "superseded" by a LARGER version of itself.
#
# Read-only with respect to ~/.claude: never writes to, locks, or touches the
# source, so it cannot interfere with a live session.
# Install (twice daily, survives reboot):
#   cp scripts/com.tranquility.transcript-backup.plist ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/com.tranquility.transcript-backup.plist
# Run once by hand:  scripts/transcript-backup.sh
# Destination override: TB_TRANSCRIPT_BACKUP=/some/where scripts/transcript-backup.sh
set -uo pipefail

SRC="${TB_TRANSCRIPT_SRC:-$HOME/.claude/projects}"
ROOT="${TB_TRANSCRIPT_BACKUP:-$HOME/ClaudeWork/transcript-backup}"
DEST="$ROOT/archive"
VERSIONS="$ROOT/versions/$(date +%Y-%m-%dT%H%M%S)"
LOG="$ROOT/snapshot.log"

[ -d "$SRC" ] || { echo "$(date -u +%FT%TZ) source missing: $SRC" >> "$LOG"; exit 1; }
mkdir -p "$DEST"

# --- shrink guard, before anything is overwritten ---
SHRUNK=0
while IFS= read -r src; do
  rel="${src#$SRC/}"
  dst="$DEST/$rel"
  [ -f "$dst" ] || continue
  s=$(stat -f%z "$src" 2>/dev/null || echo 0)
  d=$(stat -f%z "$dst" 2>/dev/null || echo 0)
  if [ "$s" -lt "$d" ]; then
    mkdir -p "$VERSIONS/$(dirname "$rel")"
    cp -p "$dst" "$VERSIONS/$rel" && SHRUNK=$((SHRUNK+1))
  fi
done < <(find "$SRC" -name '*.jsonl' -type f 2>/dev/null)

BEFORE=$(find "$DEST" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
rsync -a --exclude='*.tmp' "$SRC/" "$DEST" >/dev/null 2>>"$LOG"
RC=$?
AFTER=$(find "$DEST" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1)

echo "$(date -u +%FT%TZ) rc=$RC files=$AFTER (+$((AFTER-BEFORE))) size=$SIZE shrunk=$SHRUNK" >> "$LOG"
if [ "$SHRUNK" -gt 0 ]; then
  echo "WARNING: $SHRUNK transcript(s) got SMALLER — prior copies kept in $VERSIONS" >&2
fi
exit $RC
