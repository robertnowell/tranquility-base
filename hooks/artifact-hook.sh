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
#   2. STAMP (deterministic, inside the HQ). A page under ~/Documents/deep-research
#      is Robert's own reading archive by construction — never a client
#      deliverable — so its footer is written INTO the file here, identical on
#      every page. The judged version failed four times in one day (16 Aug):
#      pages shipped with no footer, with a hand-rolled one, and with neither
#      door. A contract that depends on remembering is not a contract.
#
#   3. OFFER (judged, everywhere else). Outside the HQ the cost is asymmetric —
#      a missing footer is a shrug, a footer on a client's slide deck is a
#      disaster — so the hook still supplies the facts and the agent decides.
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

# ---------------------------------------------------------------------------
# RECEIPT (deterministic). `gh pr create` prints the URL of the pull request it
# just made. That line is the only unambiguous record of the act, and this hook
# already sees every Bash call, so it is written down here and nowhere else.
#
# Three earlier mechanisms tried to work a pull request out of something
# adjacent — prose the summariser copied, prose a regex read, the branch the
# session was on — and each failed in a way the one before it could not see.
# The last is the sharpest: a session whose turns touch the main checkout and
# three worktrees has no single branch, and the branch it records is wherever
# its final shell command happened to leave it. The turn that opened
# `fix/the-cli-primes-the-hub` recorded `main`, because its last command was a
# `cd` to poll a deploy log.
#
# A receipt cannot do that. It is written by the command that did the thing.
python3 - "$PAYLOAD" <<'PY' 2>/dev/null || true
import json, os, re, sys, time

try:
    p = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

session = p.get("session_id") or ""
if not session or not re.fullmatch(r"[0-9a-fA-F-]{1,64}", session):
    sys.exit(0)

command = (p.get("tool_input") or {}).get("command") or ""
# `gh pr create` only. `gh pr view`, `gh pr list` and a merge are all about a
# pull request that already exists, and this file records the moment one comes
# into being — once, by the session that made it.
if not re.search(r"\bgh\s+pr\s+create\b", command):
    sys.exit(0)

# The URL comes from the OUTPUT, never from the command. A command can name a
# branch, a title, a body full of prose; only the response carries the address
# of the thing that now exists.
response = p.get("tool_response")
if isinstance(response, dict):
    text = " ".join(str(response.get(k) or "") for k in ("stdout", "output", "stderr"))
elif isinstance(response, list):
    text = " ".join(str(x) for x in response)
else:
    text = str(response or "")

urls = re.findall(r"https://[A-Za-z0-9.\-]+/[A-Za-z0-9._\-]+/[A-Za-z0-9._\-]+/pull/[0-9]+", text)
if not urls:
    sys.exit(0)

root = os.path.expanduser("~/Library/Application Support/VoiceDispatch/pullrequests")
os.makedirs(root, exist_ok=True)
stamp = int(time.time() * 1000)
with open(os.path.join(root, session), "a") as fh:
    for url in dict.fromkeys(urls):
        fh.write("%d\t%s\n" % (stamp, url))
PY

read -r SESSION FILE <<EOF
$(python3 - "$PAYLOAD" <<'PY' 2>/dev/null || true
import json, sys
try:
    p = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
session = p.get("session_id") or ""
path = (p.get("tool_input") or {}).get("file_path") or ""

# THE ARCHIVE ANSWERS, NOT THE TOOL.
#
# Keying authorship to file_path made it depend on HOW a page happened to be
# written: a heredoc, a python one-liner, or a `cp` produced no file_path, so
# the page existed, was published, was read — and was invisible to its own
# agent's hub (measured 16 Aug, on a session's own research report). A tool is
# an implementation detail of writing; the file is the fact.
#
# So when the call carries no path, ask the archive instead: any page under
# the HQ that changed in the last few minutes was changed by the turn that is
# ending right now. Cross-attribution between two simultaneous sessions is
# possible and cheap — a wrong link on a hub, fixed by the next write — where
# the failure it replaces was total silence.
if not path:
    import glob, os, time
    hq = os.path.expanduser("~/Documents/deep-research")
    recent = [f for f in glob.glob(os.path.join(hq, "*", "*.html"))
              if time.time() - os.path.getmtime(f) < 180]

    # Recency alone is not authorship. With several sessions running, every
    # one of them runs a shell command inside any three-minute window, so a
    # page being written by ONE session was claimed by all of them — the page
    # appeared on four hubs and the doctor flagged it on each (16 Aug, minutes
    # after this fallback shipped). A session wrote a page only if its own
    # transcript says so: the agent named the path when it made it. Reading
    # the tail is enough and costs nothing, and no transcript means no claim.
    if recent:
        transcript = p.get("transcript_path") or ""
        try:
            with open(transcript, "rb") as fh:
                fh.seek(0, 2)
                fh.seek(max(0, fh.tell() - 400_000))
                tail = fh.read().decode("utf-8", "replace")
        except Exception:
            tail = ""
        # A MENTION IS NOT A WRITE. Naming a slug in a grep claimed the page:
        # this session cleaned up false claims, named the slug while doing it,
        # and re-acquired the page four times (16 Aug). The record must show
        # the session WRITING it — a Write/Edit call, or a shell command that
        # redirects, copies, or opens it for writing — so the slug and the act
        # have to appear in the same transcript record.
        writes = ('"Write"', '"Edit"', '"NotebookEdit"',
                  ">", "cp ", "mv ", "tee ", "'w'", '\\"w\\"')
        def authored(slug):
            for line in tail.splitlines():
                if slug in line and any(w in line for w in writes):
                    return True
            return False
        mine = [f for f in recent
                if authored(os.path.basename(os.path.dirname(f)))]
        path = max(mine, key=os.path.getmtime) if mine else ""
    else:
        path = ""

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
  # share-as-page assembles a page from an intermediate FRAGMENT: a bare <body>
  # carrying an unsubstituted LOGO_ROOT_DATA_URI placeholder, which it then
  # wraps in the template to produce index.html. The fragment is a build input,
  # never a page -- but it is .html, so hubs listed it and the file:// link
  # rendered raw unstyled markup with a broken logo. Found on four separate
  # session hubs (20 Aug); same shape as the 15 Aug skill-template case above.
  # Match the basename anywhere: a fragment sitting inside a deploy dir is
  # still not the page.
  */body.html|*/ClaudeWork/*-build/*) exit 0;;
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

# The HQ is Robert's own archive: everything under it is a page he reads, so
# the footer is stamped rather than requested. Anything else keeps the offer.
STAMP=0
case "$FILE" in
  "$HOME"/Documents/deep-research/*.html) STAMP=1;;
esac

python3 - "$FILE" "$SESSION" "$SHORT" "$TODAY" "$STAMP" "$TITLE" <<'PY' 2>/dev/null || true
import html as htmllib
import json, re, sys

path, session, short, today, stamp = sys.argv[1:6]
title = sys.argv[6] if len(sys.argv) > 6 else ""

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

# data-tb-agent marks it as ours: the stamp replaces its own previous block
# and never touches a footer somebody else wrote.
snippet = (
    '<footer data-tb-agent="{short}" style="margin-top:64px;padding-top:20px;'
    'border-top:1px solid #ddd8cc;'
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

if stamp == "1":
    # Write it in, once, idempotently. Never fail: a footer is worth less than
    # the file it sits on, so any surprise leaves the page exactly as written.
    try:
        with open(path, "r", encoding="utf-8") as fh:
            page = fh.read()
        # Every AGENT footer goes, not just ours: a page copied from an
        # exemplar inherits the exemplar session's footer, and the copying
        # session then adds its own, which is how one audit page ended up
        # with two footers naming two different sessions (16 Aug). An agent
        # footer is one carrying the discuss link; a page's own colophon has
        # none and is left alone.
        cleaned = re.sub(
            r"<footer\b(?:(?!</footer>).)*?"
            r"(?:data-tb-agent=|tranquilitybase://discuss)"
            r"(?:(?!</footer>).)*?</footer>",
            "", page, flags=re.S)
        if "</body>" in cleaned:
            head, _, tail = cleaned.rpartition("</body>")
            stamped = head + snippet + "\n</body>" + tail
        else:
            stamped = cleaned + "\n" + snippet + "\n"
        if stamped != page:
            import os as _os
            # Keep the file's own mtime. Stamping rewrites the page, and a
            # fresh mtime made it look "just written" to the NEXT hook run,
            # which re-stamped it, which refreshed the mtime again: a page
            # that stayed permanently recent and attached itself to whichever
            # session happened to run a shell command (caught 16 Aug, minutes
            # after the archive fallback shipped).
            before = _os.stat(path)
            tmp = path + ".tb-footer"
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(stamped)
            _os.replace(tmp, path)
            _os.utime(path, (before.st_atime, before.st_mtime))
    except Exception:
        pass
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": (
            "The agent footer was stamped into {path} automatically: session "
            "id, Open hub, and Discuss with agent. Do not add another one, and "
            "do not hand-roll a footer of your own on HQ pages."
        ).format(path=path),
    }}))
else:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": context,
    }}))
PY

exit 0
