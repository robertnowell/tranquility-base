#!/bin/bash
#
# artifact hook — runs on Claude Code PostToolUse (Write).
#
# One hook, two jobs, and they are deliberately different in kind:
#
#   1. RECORD (deterministic). Every HTML file a session writes is noted as that
#      session's most recent page, so the panel can offer "open page" beside
#      "go to agent". No judgment is involved and none is wanted: the record is
#      private to this Mac, and the worst case of recording the wrong file is a
#      button you don't click.
#
#   2. OFFER (judged). The agent is handed the footer snippet — its own session
#      id, its callsign, the deep link — and decides whether this file should
#      carry it. That judgment CANNOT be automated, because the cost is
#      asymmetric: a missing footer is a shrug, and a footer on a client's slide
#      deck is a disaster. The hook supplies the facts; the agent supplies the
#      decision.
#
# Contract (same as the other two hooks):
#   1. NEVER block. This runs inside a real Claude Code turn, after every Write.
#   2. NEVER fail. Always exit 0, whatever happens.
#   3. Touch nothing but the artifact file; emit the offer on stdout.
#
# Install: hooks.PostToolUse (matcher Write) in ~/.claude/settings.json
# (`tbase install-hooks`).

set -u

SUPPORT_DIR="$HOME/Library/Application Support/VoiceDispatch"
ARTIFACTS="$SUPPORT_DIR/artifacts"
DB="$SUPPORT_DIR/queue.sqlite"

PAYLOAD=$(cat 2>/dev/null || true)
[ -z "$PAYLOAD" ] && exit 0

# The summarizer writes files too. Its subprocess carries this marker, and a
# session talking to itself about its own footer is a loop with no exit.
if [ -n "${VOICE_LOOP_MARKER:-}" ]; then
  exit 0
fi

read -r SESSION FILE <<EOF
$(python3 - "$PAYLOAD" <<'PY' 2>/dev/null || true
import json, sys
try:
    p = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
path = (p.get("tool_input") or {}).get("file_path") or ""
session = p.get("session_id") or ""
# Only pages. A .md report becomes a page later, through a different tool, and
# that write is the one that matters.
if not path.lower().endswith((".html", ".htm")):
    sys.exit(0)
if not session or not path.startswith("/"):
    sys.exit(0)
# A session id lands in a filename below; anything but hex and dashes could
# leave the directory.
if not all(c in "0123456789abcdefABCDEF-" for c in session) or len(session) > 64:
    sys.exit(0)
print(session, path)
PY
)
EOF

[ -z "${SESSION:-}" ] && exit 0
[ -z "${FILE:-}" ] && exit 0

# 1. RECORD. Write beside it and rename, so a reader sees one path or the other
#    and never half of one.
mkdir -p "$ARTIFACTS" 2>/dev/null || exit 0
printf '%s\n' "$FILE" > "$ARTIFACTS/$SESSION.tmp" 2>/dev/null \
  && mv -f "$ARTIFACTS/$SESSION.tmp" "$ARTIFACTS/$SESSION" 2>/dev/null

# 2. OFFER. The callsign is the app's, minted at the session's first summary, so
#    it is read from the app's own store — read-only, with a short timeout, and
#    every failure falls through to the session id alone. A hook that hangs on a
#    locked database would stall a real turn, which is worse than an unnamed
#    footer.
CALLSIGN=""
if [ -r "$DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  CALLSIGN=$(sqlite3 -cmd ".timeout 400" \
    "file:$DB?mode=ro&immutable=0" \
    "select callsign from session_callsign where sessionId='$SESSION' limit 1;" \
    2>/dev/null | head -1)
fi
[ -z "$CALLSIGN" ] && CALLSIGN="this agent"

# The session's OTHER name, and the one the user recognizes first: the string
# Claude Code puts in the terminal tab, which is also the identity the grid
# shows. It is not the callsign and must not be confused with it — the callsign
# is minted here, to be SAID, and stays frozen; the title is written by the
# harness, describes the work, and changes as the work does. A footer with only
# one of them makes the reader do a lookup, so it carries both.
#
# Same source the app uses (TranscriptTitles): the last `ai-title` record in the
# session transcript. Read straight from the file so this needs nothing running.
TITLE=$(python3 - "$PAYLOAD" <<'PY' 2>/dev/null || true
import json, sys
try:
    p = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
path = p.get("transcript_path") or ""
title = ""
try:
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"ai-title"' not in line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "ai-title" and rec.get("aiTitle"):
                title = rec["aiTitle"]
except Exception:
    pass
print(title.replace("\n", " ").strip()[:120])
PY
)

SHORT="${SESSION%%-*}"
TODAY=$(date "+%d %b %Y")

python3 - "$FILE" "$SESSION" "$SHORT" "$CALLSIGN" "$TODAY" "$TITLE" <<'PY' 2>/dev/null || true
import html as htmllib
import json, sys

path, session, short, callsign, today = sys.argv[1:6]
title = sys.argv[6] if len(sys.argv) > 6 else ""

# Both names, in the order the reader resolves them: the tab title says WHAT
# the session is doing, the callsign says which voice speaks it, the id is what
# survives when neither app is installed.
who = "Created by <b>{title}</b> &middot; callsign <b>{callsign}</b>".format(
    title=htmllib.escape(title), callsign=htmllib.escape(callsign)
) if title else "Created by <b>{callsign}</b>".format(callsign=htmllib.escape(callsign))

snippet = (
    '<footer style="margin-top:64px;padding-top:20px;border-top:1px solid #ddd8cc;'
    'font:13px/1.5 ui-monospace,Menlo,monospace;color:#8f8a7c;'
    'display:flex;flex-wrap:wrap;gap:14px;align-items:center">\n'
    '  <div style="flex:1;min-width:220px">{who}<br>session {short} &middot; {today}</div>\n'
    '  <a href="tranquilitybase://discuss?session={session}&amp;ref={path}" '
    'style="text-decoration:none;background:#1f4f8f;color:#fbfaf8;padding:8px 14px;'
    'border-radius:7px;font-weight:640">Discuss with agent</a>\n'
    '</footer>'
).format(who=who, short=short, today=today, session=session, path=path)

context = (
    "You just wrote an HTML file: {path}\n\n"
    "If it is a SESSION ARTIFACT — a plan, an analysis, a status page, a visual "
    "explanation, a report for this user to read — add this footer immediately "
    "before </body>, restyled to match the page you built (the markup below is "
    "the contract; the styling is yours):\n\n"
    "{snippet}\n\n"
    "It exists so the user can get back to the agent that made the page: the "
    "button opens this session in Tranquility Base, and the session id "
    "correlates the artifact to the conversation even with no app installed. "
    "It carries BOTH of this session's names, which are different things — the "
    "title is what your harness calls this conversation, the callsign is what "
    "Tranquility Base says out loud.\n\n"
    "The footer states facts and nothing else. No commentary about the footer, "
    "no note about what it demonstrates, no aside to the reader.\n\n"
    "Name no coding agent anywhere in it. Which agent wrote the page is a fact "
    "with a short shelf life; the session's own two names are not.\n\n"
    "Do not add it to a client deliverable, a marketing email, a slide deck, a "
    "rendered video frame, or any file that is not intended to be viewed by a "
    "human as a report."
).format(path=path, snippet=snippet)

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": context,
}}))
PY

exit 0
