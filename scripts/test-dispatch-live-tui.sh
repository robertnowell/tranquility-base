#!/bin/bash
# Dispatch, against a REAL harness TUI.
#
# The gap this closes, stated plainly: scripts/test-dispatch-tmux.sh is nine
# good tests against a plain SHELL, which has no prompt glyph — so the composer
# reader (`classifyPromptLine`, `boxRows`, `boxHolds`, the floor decision) is
# never exercised by it at all. That reader broke eight times in eight days
# between 19 and 26 Aug, and every one of the eight was found by a human losing
# a message, because nothing in CI could see the code. This runs the real
# harness and asserts on its transcript.
#
# Usage: scripts/test-dispatch-live-tui.sh
set -uo pipefail
cd "$(dirname "$0")/.."

# The app's OWN socket, with a tb- session name, because that is the only
# place TmuxOwnership looks — a private socket would be invisible to the
# transport under test, which would make this drill test nothing. Only this
# session is created and only this session is killed.
SOCKET="tb"
SESSION="tb-livedrill$$"
DIR="/private/tmp/tb-live-tui-$$"
export TMUX_TMPDIR="$HOME/Library/Application Support/VoiceDispatch/tmux"
mkdir -p "$DIR"
TMUX=$(command -v tmux || echo /usr/local/bin/tmux)
PASS=0; FAIL=0

cleanup() {
  "$TMUX" -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null
  rm -rf "$DIR"
}
trap cleanup EXIT

ok()   { echo "  ok    $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

echo "live TUI dispatch (socket $SOCKET)"

echo "→ starting a real Claude Code session"
"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -x 120 -y 40 -c "$DIR" \
  -e "PATH=$HOME/.local/bin:/usr/bin:/bin" \
  /bin/zsh -c "cd '$DIR' && claude --dangerously-skip-permissions" >/dev/null 2>&1
sleep 14
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter 2>/dev/null   # clear any trust prompt
sleep 5

SID=$(claude agents --json 2>/dev/null | python3 -c "
import sys,json
try: a=json.load(sys.stdin)
except Exception: a=[]
for s in a:
    if '$DIR' == (s.get('cwd') or ''): print(s.get('sessionId')); break
")
if [ -z "$SID" ]; then echo "  FAIL  could not find the session; is claude logged in?"; exit 1; fi
echo "  session $SID"
swift build 2>/dev/null >/dev/null
TB=./.build/debug/tbase
"$TB" enroll "$SID" >/dev/null 2>&1

transcript() { ls "$HOME/.claude/projects/"*"/$SID.jsonl" 2>/dev/null | head -1; }

# count user-visible deliveries (user records + queue enqueues) containing a needle
count() {
  python3 - "$(transcript)" "$1" <<'PY'
import json,io,sys
path,needle=sys.argv[1],sys.argv[2]
users=queued=0
if path:
    for l in io.open(path,encoding="utf-8",errors="replace"):
        try: d=json.loads(l)
        except: continue
        if d.get("type")=="queue-operation" and d.get("operation")=="enqueue":
            if needle in (d.get("content") or ""): queued+=1
        elif d.get("type")=="user":
            m=d.get("message") or {}; c=m.get("content")
            t=c if isinstance(c,str) else " ".join(
                x.get("text","") for x in (c or []) if isinstance(x,dict) and x.get("type")=="text")
            if t and needle in t: users+=1
# A message delivered into a BUSY session is written twice by the harness --
# once when it is enqueued, again as a user record when the turn consumes it.
# Counting both would report one delivery as two, which is exactly the kind of
# false alarm this drill exists to rule out.
print(users if users else queued)
PY
}

put_in_box() { printf '%s' "$1" | "$TMUX" -L "$SOCKET" load-buffer -b pre - && \
               "$TMUX" -L "$SOCKET" paste-buffer -b pre -d -p -t "$SESSION"; sleep 2; }

# ── 1. the ordinary case
SEND1=$("$TB" send "$SID" "MARKER-ONE please do nothing" 2>&1 | tail -1); echo "  send1: $SEND1"
sleep 3
[ "$(count MARKER-ONE)" = "1" ] && ok "empty composer: exactly one delivery" \
                                || bad "empty composer: $(count MARKER-ONE) deliveries"

# ── 2. text already in the box, one row
put_in_box "KEEPME-TWO a note the human typed"
"$TB" send "$SID" "MARKER-TWO please do nothing" >/dev/null 2>&1
sleep 3
[ "$(count MARKER-TWO)" = "1" ] && ok "one-row floor: exactly one delivery" \
                                || bad "one-row floor: $(count MARKER-TWO) deliveries"
[ "$(count KEEPME-TWO)" -ge "1" ] && ok "one-row floor: the human's text was not deleted" \
                                  || bad "one-row floor: the human's text was DELETED"

# ── 3. the 26 Aug shape: caret row empty, text on the rows below
put_in_box "$(printf '\nKEEPME-THREE a note long enough that the terminal user interface has to draw it across more than one row below the caret, which is the exact shape that read as an empty box')"
"$TB" send "$SID" "MARKER-THREE please do nothing" >/dev/null 2>&1
sleep 3
[ "$(count MARKER-THREE)" = "1" ] && ok "multi-row floor: exactly one delivery" \
                                  || bad "multi-row floor: $(count MARKER-THREE) deliveries"
[ "$(count KEEPME-THREE)" -ge "1" ] && ok "multi-row floor: the human's text was not deleted" \
                                    || bad "multi-row floor: the human's text was DELETED"

# ── 4. two writers, one composer, no gap at all
#
# The invariant is NOT "both land". Two processes racing for one text box is a
# case where refusing is a legitimate answer, and the transport does refuse —
# out loud, to its caller, with the words kept. What must never happen is a
# duplicate, or a silent loss. So: each marker at most once, and a send that
# says "confirmed" must be exactly once.
"$TB" send "$SID" "MARKER-FOUR please do nothing" > /private/tmp/s4.$$ 2>&1 &
"$TB" send "$SID" "MARKER-FIVE please do nothing" > /private/tmp/s5.$$ 2>&1 &
wait
S4=$(tail -1 /private/tmp/s4.$$); S5=$(tail -1 /private/tmp/s5.$$)
rm -f /private/tmp/s4.$$ /private/tmp/s5.$$
sleep 6
C4=$(count MARKER-FOUR); C5=$(count MARKER-FIVE)
[ "$C4" -le 1 ] && ok "concurrent: first is never duplicated ($C4)" \
                || bad "concurrent: first delivered $C4 times"
[ "$C5" -le 1 ] && ok "concurrent: second is never duplicated ($C5)" \
                || bad "concurrent: second delivered $C5 times"
for pair in "4:$S4:$C4" "5:$S5:$C5"; do
  n=${pair%%:*}; rest=${pair#*:}; said=${rest%:*}; got=${rest##*:}
  case "$said" in
    confirmed*) [ "$got" = "1" ] && ok "concurrent: send $n said confirmed and landed once" \
                                 || bad "concurrent: send $n said confirmed but landed $got times" ;;
    *)          [ "$got" = "0" ] && ok "concurrent: send $n refused out loud and delivered nothing" \
                                 || bad "concurrent: send $n refused but delivered $got" ;;
  esac
done

echo
echo "live TUI dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
