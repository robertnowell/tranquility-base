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

# Never an artifact, and never worth a footer: render probes in a session
# scratchpad, anything in the system temp trees, and the harness's own
# library. Mirrors ArtifactStore.excluded — editing a skill template once put
# the blank template on a hub as "page.html" (15 Aug).
case "$FILE" in
  */scratchpad/*|/tmp/*|/private/tmp/*|/var/folders/*|*/.claude/*) exit 0;;
  */Documents/agents/*) exit 0;;   # a hub is the index over artifacts, not one
esac

# 1. RECORD. Append `ms<TAB>path`, the same line ArtifactStore.record writes —
#    the file stopped being "the latest page" the day the hub grew a page LIST,
#    and this hook kept replacing it: one truncating printf clobbered a
#    session's whole history down to a single undated line, which the hub then
#    rendered as "31 Dec" (epoch zero) until backfill re-mined the transcript.
#    An O_APPEND write of one short line is atomic; duplicates are fine — the
#    reader dedupes by path and keeps the first stamp.
mkdir -p "$ARTIFACTS" 2>/dev/null || exit 0
printf '%s\t%s\n' "$(($(date +%s) * 1000))" "$FILE" >> "$ARTIFACTS/$SESSION" 2>/dev/null

# 2. OFFER. The footer's name is the session TITLE alone — the string Claude
#    Code puts in the terminal tab, the identity the grid shows, the one the
#    user recognizes first. The callsign was here too and was killed by ruling
#    (15 Aug): it is a voice, minted to be SAID, and on a page it read as a
#    second confusing name. The session id rides the same line as the title;
#    the id is what survives when neither app is installed.
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

python3 - "$FILE" "$SESSION" "$SHORT" "$TODAY" "$TITLE" <<'PY' 2>/dev/null || true
import html as htmllib
import json, sys

path, session, short, today = sys.argv[1:5]
title = sys.argv[5] if len(sys.argv) > 5 else ""

# The way UP: every artifact links its agent's hub — the page that lists
# everything this agent made — so the correlation runs both directions even
# from a page found weeks later in a browser tab. The hub's address is the
# slug alone (ruled: nothing but the id in the name), so it is computable
# here with nothing running.
import os
hub = os.path.expanduser("~/Documents/agents/{}/index.html".format(short))

# One name and one number: the tab title says WHAT the session did, the id
# beside it is the durable handle. The date closes the line.
who = ("Created by <b>{title}</b> &middot; session {short} &middot; {today}"
       .format(title=htmllib.escape(title), short=short, today=today)
       if title else
       "Created by session {short} &middot; {today}".format(short=short, today=today))

snippet = (
    '<footer style="margin-top:64px;padding-top:20px;border-top:1px solid #ddd8cc;'
    'font:13px/1.5 ui-monospace,Menlo,monospace;color:#8f8a7c;'
    'display:flex;flex-wrap:wrap;gap:10px;align-items:center">\n'
    '  <div style="flex:1;min-width:220px">{who}</div>\n'
    '  <a href="file://{hub}" '
    'style="text-decoration:none;color:#5d5a51;border:1px solid #ddd8cc;'
    'padding:7px 13px;border-radius:7px;font-weight:640">Open hub</a>\n'
    '  <a href="tranquilitybase://discuss?session={session}&amp;ref={path}" '
    'style="text-decoration:none;background:#1f4f8f;color:#fbfaf8;padding:8px 14px;'
    'border-radius:7px;font-weight:640">Discuss with agent</a>\n'
    '</footer>'
).format(who=who, short=short, today=today, session=session, path=path,
         hub=hub)

context = (
    "You just wrote an HTML file: {path}\n\n"
    "If it is a SESSION ARTIFACT — a plan, an analysis, a status page, a visual "
    "explanation, a report for this user to read — add this footer immediately "
    "before </body>, restyled to match the page you built (the markup below is "
    "the contract; the styling is yours):\n\n"
    "{snippet}\n\n"
    "It exists so the user can get back to the agent that made the page: the "
    "primary button opens this session in Tranquility Base, the secondary "
    "button opens this agent's hub (the page listing everything it made), and "
    "the session id on the title line correlates the artifact to the "
    "conversation even with no app installed.\n\n"
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
