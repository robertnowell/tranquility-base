#!/bin/bash
# Continue with, against a REAL harness TUI: both ways the conversation travels.
#
#   1. The pasted log. The first message of a cross-harness continuation is
#      about 175,000 characters. Nothing else in the app pastes a message a
#      hundredth that size, so "the paste path works" was never evidence
#      about this one. Sent through the real transport, asserted on the
#      transcript: delivered once, and whole.
#   2. The native fork. `--resume <id> --fork-session` is run while the source
#      is STILL RUNNING, which is the only way Continue with ever runs it. The
#      fork must hold the source's messages under a new id, and the source's
#      transcript must not change.
#
# Same isolation as scripts/test-dispatch-live-tui.sh, and the same cleanup.
# Costs model calls; run by hand.
#
# Usage: scripts/test-handoff-live-tui.sh <any session log to paste the end of> <its harness id>
set -uo pipefail
cd "$(dirname "$0")/.."
LOG="${1:?a session log to paste the end of}"
HARNESS="${2:?the harness that wrote it: claude-code or codex}"

export VOICE_DISPATCH_SUPPORT_DIR="/private/tmp/tb-drill-support-$$"
mkdir -p "$VOICE_DISPATCH_SUPPORT_DIR"
SOCKET="tb"
SESSION="tb-handoffdrill$$"
FORK="tb-handoffdrillfork$$"
DIR="/private/tmp/tb-handoff-tui-$$"
export TMUX_TMPDIR="$VOICE_DISPATCH_SUPPORT_DIR/tmux"
mkdir -p "$TMUX_TMPDIR" "$DIR"
TMUX=$(command -v tmux || echo /usr/local/bin/tmux)
PASS=0; FAIL=0
SIDS=""

cleanup() {
  "$TMUX" -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null
  "$TMUX" -L "$SOCKET" kill-session -t "$FORK" 2>/dev/null
  rm -rf "$VOICE_DISPATCH_SUPPORT_DIR" "$DIR"
  for sid in $SIDS; do
    for t in "$HOME/.claude/projects/"*"/$sid.jsonl"; do
      [ -f "$t" ] || continue
      d="$(dirname "$t")"
      rm -f "$t"
      if [ -z "$(find "$d" -name '*.jsonl' -print -quit 2>/dev/null)" ]; then rm -rf "$d"; fi
    done
  done
}
trap cleanup EXIT
ok()  { echo "  ok    $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

accept_trust() {
  local screen cursor accept steps
  screen=$("$TMUX" -L "$SOCKET" capture-pane -p -t "$1" 2>/dev/null || true)
  cursor=$(printf '%s\n' "$screen" | grep -n '❯' | head -1 | cut -d: -f1)
  accept=$(printf '%s\n' "$screen" | grep -n 'Yes, I trust this folder' | head -1 | cut -d: -f1)
  if [ -n "$cursor" ] && [ -n "$accept" ]; then
    steps=$(( accept - cursor ))
    while [ "$steps" -gt 0 ]; do "$TMUX" -L "$SOCKET" send-keys -t "$1" Down; steps=$(( steps - 1 )); done
    "$TMUX" -L "$SOCKET" send-keys -t "$1" Enter
  fi
}
sessions_here() {
  claude agents --json 2>/dev/null | python3 -c "
import sys,json
try: a=json.load(sys.stdin)
except Exception: a=[]
for s in a:
    if '$DIR' == (s.get('cwd') or ''): print(s.get('sessionId'))
"
}
transcript() { ls "$HOME/.claude/projects/"*"/$1.jsonl" 2>/dev/null | head -1; }
start() {
  "$TMUX" -L "$SOCKET" new-session -d -s "$1" -x 120 -y 40 -c "$DIR" \
    -e "PATH=$HOME/.local/bin:/usr/bin:/bin" \
    -e "VOICE_DISPATCH_SUPPORT_DIR=$VOICE_DISPATCH_SUPPORT_DIR" \
    /bin/zsh -c "cd '$DIR' && $2" >/dev/null 2>&1
}

echo "handoff, live TUI (socket $SOCKET)"
swift build --product tbase >/dev/null 2>&1
TB=./.build/debug/tbase

echo "→ the pasted log"
start "$SESSION" "claude --dangerously-skip-permissions"
sleep 14; accept_trust "$SESSION"; sleep 5
SID=$(sessions_here | head -1)
if [ -z "$SID" ]; then echo "  FAIL  could not find the session; is claude logged in?"; exit 1; fi
SIDS="$SID"
echo "  session $SID"
"$TB" enroll "$SID" >/dev/null 2>&1
MESSAGE="$("$TB" handoff-text drill-source "$HARNESS" "$LOG" --hq-log "$PWD/skills/bin/hq-log")

HANDOFF-MARKER-$$ Reply with the single word ok and do nothing else."
echo "  first message: ${#MESSAGE} characters"
printf '%s' "$MESSAGE" > "$DIR/sent"
SENT=$("$TB" send "$SID" "$MESSAGE" 2>&1 | tail -1); echo "  send: $SENT"
sleep 20
python3 - "$(transcript "$SID")" "HANDOFF-MARKER-$$" "$DIR/sent" <<'PY' > "$DIR/verdict"
import json,io,sys
path,marker=sys.argv[1],sys.argv[2]
sent=io.open(sys.argv[3],encoding="utf-8").read()
found=[]
for l in io.open(path,encoding="utf-8",errors="replace"):
    try: d=json.loads(l)
    except ValueError: continue
    if d.get("type")!="user": continue
    c=(d.get("message") or {}).get("content")
    t=c if isinstance(c,str) else "\n".join(x.get("text","") for x in (c or []) if isinstance(x,dict) and x.get("type")=="text")
    if marker in t: found.append(t)
# The transport sends every message as one line (DispatchText.flatten), and the
# harness wraps a large paste in its own tag. So "whole" is every character
# that is not whitespace, in order, inside what the transcript holds.
squeeze=lambda t: "".join(t.split())
print(len(found))
print(len(squeeze(found[0])) if found else 0)
print(len(squeeze(sent)))
print(1 if found and squeeze(sent) in squeeze(found[0]) else 0)
PY
N=$(sed -n 1p "$DIR/verdict"); GOT=$(sed -n 2p "$DIR/verdict"); WANT=$(sed -n 3p "$DIR/verdict"); WHOLE=$(sed -n 4p "$DIR/verdict")
[ "$N" = "1" ] && ok "pasted log: delivered exactly once" || bad "pasted log: $N deliveries"
[ "$WHOLE" = "1" ] && ok "pasted log: all $WANT non-space characters reached the transcript, in order" \
                   || bad "pasted log: the transcript holds $GOT non-space characters and the message has $WANT"

echo "→ the native fork, of a running session"
sleep 10
BEFORE=$(stat -f %z "$(transcript "$SID")"); SUM=$(md5 -q "$(transcript "$SID")")
ARGS=$("$TB" fork-arguments claude-code "$SID")
echo "  claude $ARGS"
start "$FORK" "claude --dangerously-skip-permissions $ARGS"
sleep 16
NEW=$(sessions_here | grep -v "$SID" | head -1)
if [ -z "$NEW" ]; then
  bad "fork: no second session appeared in $DIR"
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$FORK" 2>/dev/null | tail -15
else
  SIDS="$SID $NEW"
  ok "fork: a new session id appeared ($NEW)"
  "$TB" enroll "$NEW" >/dev/null 2>&1
  "$TB" send "$NEW" "FORK-MARKER-$$ Which marker word did my previous message start with? Reply with that word only." >/dev/null 2>&1
  sleep 25
  grep -q "HANDOFF-MARKER-$$" "$(transcript "$NEW")" 2>/dev/null \
    && ok "fork: the new transcript holds the source's message" \
    || bad "fork: the new transcript does not hold the source's message"
  python3 - "$(transcript "$NEW")" "HANDOFF-MARKER-$$" "FORK-MARKER-$$" <<'PY' > "$DIR/answer"
import json,io,sys
path,want,ask=sys.argv[1:4]
seen=False; said=""
for l in io.open(path,encoding="utf-8",errors="replace"):
    try: d=json.loads(l)
    except ValueError: continue
    c=(d.get("message") or {}).get("content")
    t=c if isinstance(c,str) else "\n".join(x.get("text","") for x in (c or []) if isinstance(x,dict) and x.get("type")=="text")
    if d.get("type")=="user" and ask in t: seen=True
    elif d.get("type")=="assistant" and seen and t.strip(): said=t
print(1 if want in said else 0)
PY
  [ "$(cat "$DIR/answer")" = "1" ] && ok "fork: the new agent answered from the source's conversation" \
                                   || bad "fork: the new agent did not recall the source's message"
  [ "$(md5 -q "$(transcript "$SID")")" = "$SUM" ] && ok "fork: the source transcript is byte-identical ($BEFORE bytes)" \
                                                  || bad "fork: the source transcript changed"
fi

echo "handoff live TUI: $PASS ok, $FAIL failed"
[ "$FAIL" = "0" ]
