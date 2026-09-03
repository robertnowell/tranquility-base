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

read -r OWNER SESSION MISFILED FILE <<EOF
$(python3 - "$PAYLOAD" <<'PY' 2>/dev/null || true
import json, os, sys
try:
    p = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
session = p.get("session_id") or ""      # who ran the tool: the full id
owner = session                          # who the page belongs to
path = (p.get("tool_input") or {}).get("file_path") or ""

# THE PATH ANSWERS FIRST.
#
# A page at ~/Documents/agents/<slug>/<name>.html states its own author, so
# there is nothing to infer: no glob over likely directories, no transcript tail,
# no hoping that two simultaneous sessions do not both claim it. That guessing
# machinery exists only because nothing was ever agreed about where pages go, and
# it is what put one page on four hubs (16 Aug). Sessions are told the location
# by visual-output-hook now, so this is the common case, not the exception.
#
# The session in the payload still wins if they disagree -- it is the more direct
# fact -- but a page filed under another agent's slug is recorded for THAT agent,
# because the path is a deliberate act and the payload is just whoever ran the
# tool.
# The record is keyed by the SLUG here, not the full session id, because the slug
# is all a path carries. ArtifactStore.history reads both files for a session, so
# a slug-keyed record is found by the hub that owns it.
_agents = os.path.expanduser("~/Documents/agents")

# The INDEXER's own pages are not artifacts.
#
# `publish.py` writes the private index and the hub of hubs into a configurable
# root, so no path rule can name them; they announce themselves instead, with a
# marker in the first line. Without this, every session that rebuilds the index
# has that file recorded as a page it made, and `tbase doctor` reports it as
# missing from a hub that will never list it — which is true, and useless. Seen
# twice on 02 Sep, under two different sessions, within an hour.
def _is_generated_index(f):
    try:
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            return "research-hq-generated: index" in fh.read(2048)
    except OSError:
        return False


def _is_hub(f):
    # The hub is ONE file per agent: agents/<slug>/index.html. Matching on the
    # filename alone also names agents/<slug>/<date-slug>/index.html, which is a
    # research brief and the single most common shape a report takes. Excluding
    # it here meant a brief was never claimed by its own path.
    return (os.path.basename(f) == "index.html"
            and os.path.dirname(os.path.dirname(f)) == _agents)

if path and _is_generated_index(path):
    path = ""

# THE WRITER OWNS THE PAGE. The directory is where it should be.
#
# This used to read the owner straight off the path, on the reasoning that
# filing a page under an agent's slug is a deliberate act. It is not always.
# On 02 Sep session 95d165f8 wrote two of its own reports into 4394c0ec's
# directory with a heredoc, and the path rule then stamped 4394c0ec's id, name
# and discuss link into both — so the archive asserted the wrong author, and
# BOTH hubs linked the pages. Robert: "these agents are linking to the wrong
# reports. That can never happen."
#
# A disagreement between the writer and the directory is a defect, and a defect
# is reported, not laundered into provenance. The writer keeps ownership; the
# misfile is named in the message so it gets moved.
misfiled = ""
if path and "/Documents/agents/" in path and not _is_hub(path):
    parts = path.split(os.sep)
    if "agents" in parts:
        _i = parts.index("agents")
        if _i + 1 < len(parts) and parts[_i + 1]:
            in_dir = parts[_i + 1]
            if not session or in_dir == session.split("-")[0]:
                owner = in_dir
            else:
                misfiled = in_dir

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
    # WHERE PAGES ACTUALLY GET BUILT, not just the HQ.
    #
    # This scanned ~/Documents/deep-research alone, so a page built by a script
    # anywhere else was invisible to BOTH attribution paths: no file_path because
    # it was not a Write, and not in the HQ so the fallback never saw it either.
    # Measured 21 Aug: ~/Projects/contract-proof/brief-coframe.html (168KB, full
    # document) and ~/Projects/coframe-issues/index.html (164KB) were recorded
    # NOWHERE, so their sessions' hubs listed no report at all -- which is the
    # whole point of a hub.
    #
    # The cwd first, because the session's own directory is the strongest signal
    # of its own work, then the two trees this house builds pages in. Depth is
    # capped at the project dir and one level under it: pages live at
    # <project>/index.html or <project>/<name>.html, and an unbounded walk of
    # ~/Projects would stat thousands of node_modules files on every Bash call.
    roots = []
    cwd = p.get("cwd") or ""
    if cwd.startswith("/"):
        roots += [os.path.join(cwd, "*.html"), os.path.join(cwd, "*", "*.html")]
    for tree in ("~/Documents/deep-research", "~/Projects", "~/ClaudeWork"):
        base = os.path.expanduser(tree)
        roots += [os.path.join(base, "*", "*.html"), os.path.join(base, "*.html")]
    # THIS SESSION'S OWN HUB, which was missing and is where reports actually
    # live. Without it a page written by a shell command into
    # ~/Documents/agents/<short>/ was never found, so it was never recorded and
    # never stamped.
    #
    # That is the whole reason Codex pages had no footer, and it was never a
    # Codex rule: Codex's only tool is `exec`, so EVERY Codex write takes this
    # branch. Claude Code took it too whenever it wrote a page with a heredoc
    # rather than the Write tool, which is why some Claude hubs had footers on
    # Monday and some did not, hours apart, with no pattern anyone could see.
    own_hub = os.path.expanduser("~/Documents/agents/{}".format(session.split("-")[0]))
    # BOTH LEVELS. A page sits at agents/<slug>/<name>.html, and a research
    # report sits at agents/<slug>/<date-slug>/index.html -- a dated directory
    # holding report.md beside index.html, which is the canonical layout and
    # where 452 of them live. Globbing only the flat level meant every research
    # brief written by a heredoc or by Codex was invisible to this branch: not
    # found, so not recorded, so not stamped, so not on any hub.
    roots.append(os.path.join(own_hub, "*.html"))
    roots.append(os.path.join(own_hub, "*", "*.html"))
    seen_paths = set()
    recent = []
    for pattern in roots:
        for f in glob.glob(pattern):
            # THE HUB IS NOT A CANDIDATE, and leaving it in was the bug.
            #
            # The declared-path branch has excluded it since the beginning; this
            # one never did. The app rewrites agents/<slug>/index.html at every
            # turn end, so in a session that is doing anything at all the hub is
            # almost always the newest HTML in the directory — newer than the
            # page the session just wrote. The recency contest then picks the
            # hub, the real page is never recorded and never stamped, and the
            # hub gets an agent footer written into a file the app owns and
            # overwrites.
            #
            # This is the whole of "some pages have footers and some do not,
            # hours apart, with no pattern anyone could see" (02 Sep,
            # 1605072d/tmux-fork-drift.html): the pattern was whether the app
            # happened to rewrite the hub inside the same three-minute window.
            if f in seen_paths or "/node_modules/" in f or "/.git/" in f \
                    or _is_hub(f) or _is_generated_index(f):
                continue
            seen_paths.add(f)
            try:
                if time.time() - os.path.getmtime(f) < 180:
                    recent.append(f)
            except OSError:
                pass

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
        # A page inside THIS session's own hub is authored by construction:
        # the directory is named after the session that owns it. That is
        # stronger evidence than the transcript scan below, and it is the only
        # evidence available to a harness whose payload carries no transcript
        # at all, which is the second half of why Codex never qualified.
        mine = [f for f in recent
                if os.path.dirname(f) == own_hub
                or os.path.dirname(os.path.dirname(f)) == own_hub]
        mine += [f for f in recent
                 if f not in mine and authored(os.path.basename(os.path.dirname(f)))]
        path = max(mine, key=os.path.getmtime) if mine else ""
    else:
        path = ""

# Only pages. A .md report becomes a page later, through a different tool, and
# that write is the one that matters.
if not path.lower().endswith((".html", ".htm")):
    sys.exit(0)
if not owner or not session or not path.startswith("/"):
    sys.exit(0)
# A session id lands in a filename below; anything but hex and dashes could
# leave the directory.
if not all(c in "0123456789abcdefABCDEF-" for c in owner + session) or len(owner) > 64:
    sys.exit(0)
# TWO FACTS, NOT ONE.
#
# `owner` is who the page belongs to, and the path decides it: a page under
# agents/<slug>/ is that agent's, however it was written. That is the record key.
#
# `session` is who ran the tool, from the payload, and it is the only full
# session id in play. The deep link needs it: the app resolves `discuss` with an
# exact lookup keyed on the full id, so a footer carrying the 8-character slug
# says "no agent" for a session that is running in the foreground. Collapsing
# both facts into one variable is what broke the button on 107 pages.
print(owner, session, misfiled or "-", path)
PY
)
EOF

[ -z "${OWNER:-}" ] && exit 0
[ -z "${SESSION:-}" ] && exit 0
[ -z "${FILE:-}" ] && exit 0

# Never an artifact, and never worth a footer: render probes in a session
# scratchpad, anything in the system temp trees, and the harness's own
# library. Mirrors ArtifactStore.excluded — editing a skill template once put
# the blank template on a hub as "page.html" (15 Aug).
case "$FILE" in
  */scratchpad/*|/tmp/*|/private/tmp/*|/var/folders/*|*/.claude/*) exit 0;;
esac

# The HUB is not an artifact. But the agents tree is where reports LIVE --
# agents/<slug>/<name>.html names its own author in its own path -- so only the
# hub is excluded, not the whole directory. Mirrors ArtifactStore.excluded.
#
# EXACT, not a glob. `case` patterns match across slashes, so the obvious
# */Documents/agents/*/index.html also names agents/<slug>/<date-slug>/index.html
# -- a research brief, and very much an artifact. The comment above this rule
# already said "only index.html is excluded"; the pattern quietly said something
# wider, and would drop every report filed under an agent.
if [ "$(basename "$FILE")" = "index.html" ] \
   && [ "$(dirname "$(dirname "$FILE")")" = "$HOME/Documents/agents" ]; then
  exit 0
fi

# RESOLVE TO WHAT RENDERS.
#
# Every HTML a session writes is a report and belongs on the hub. What the hub
# may not do is link something that renders unstyled -- share-as-page writes a
# bare <body> (no doctype, no stylesheet, no footer) and the built page into the
# same folder, and on 21 Aug a hub served the fragment: default Times with the
# stat block collapsed into running prose.
#
# Excluding fragments was the first answer and it is wrong -- it deletes the
# report rather than showing it properly. So there is no skip list. One question
# is asked of every file: what is the faithful rendering of this? A complete
# document renders as itself; a fragment renders as the index.html beside it.
#
# A doctype is the test, because a name is not: the pipeline produced four
# shapes in two days (body.html, body.snippet.html, x.body.html,
# x-page-body.html) and the pattern written for the first shipped hours before
# the next two appeared. Bytes cannot be renamed.
if [ -r "$FILE" ] && ! head -c 512 "$FILE" 2>/dev/null | grep -qiE '<!doctype|<html'; then
  SIBLING="$(dirname "$FILE")/index.html"
  if [ "$(dirname "$(dirname "$SIBLING")")" = "$HOME/Documents/agents" ]; then
    # THE SIBLING IS THIS AGENT'S HUB. Leave FILE alone.
    #
    # This rule was written for share-as-page, which builds <slug>/body.html
    # beside <slug>/index.html, so "the index next door" means "the built
    # page". An agent's own directory is flat and has no build step: the
    # index.html beside a page there is the HUB, and a page written into it is
    # the artifact whether or not it opens with a doctype.
    #
    # Redirecting served the hub instead of the page: the real page was never
    # recorded and never stamped, and the footer was written into a file the
    # app overwrites at the next turn end. That is the whole of
    # agents/1605072d/tmux-fork-drift.html arriving with no footer on 02 Sep —
    # a complete, styled report whose only sin was starting with <meta> instead
    # of <!doctype>.
    :
  elif [ -r "$SIBLING" ] && head -c 512 "$SIBLING" 2>/dev/null \
       | grep -qiE '<!doctype|<html'; then
    FILE="$SIBLING"
  else
    # Mid-build: nothing faithful to show yet. The finished page records itself
    # when it is written, so nothing is lost by waiting for it.
    exit 0
  fi
fi

# 1. RECORD. Append `ms<TAB>path`, the same line ArtifactStore.record writes —
#    the file stopped being "the latest page" the day the hub grew a page LIST,
#    and this hook kept replacing it: one truncating printf clobbered a
#    session's whole history down to a single undated line, which the hub then
#    rendered as "31 Dec" (epoch zero) until backfill re-mined the transcript.
#    An O_APPEND write of one short line is atomic; duplicates are fine — the
#    reader dedupes by path and keeps the first stamp.
mkdir -p "$ARTIFACTS" 2>/dev/null || exit 0
#    Keyed by the OWNER, which for a page under agents/<slug>/ is the slug the
#    path names. That is deliberate and predates this change: the slug is all a
#    path carries, and ArtifactStore.history reads both the slug file and the
#    full-id file for a session, so a slug-keyed record is found by the hub that
#    owns it. Only the deep link needs the full id, and it gets it separately.
printf '%s\t%s\n' "$(($(date +%s) * 1000))" "$FILE" >> "$ARTIFACTS/$OWNER" 2>/dev/null

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

SHORT="${OWNER%%-*}"
# The link carries the FULL id when the writer is the owner, which is the common
# case and the one the app can resolve today. When a session writes into another
# agent's directory the owner's full id is not knowable from a path, so the link
# names the slug and the app resolves the prefix (issue #251).
LINK_SESSION="$SESSION"
[ "${SESSION%%-*}" = "$SHORT" ] || LINK_SESSION="$SHORT"
TODAY=$(date "+%d %b %Y")

# The HQ is Robert's own archive: everything under it is a page he reads, so
# the footer is stamped rather than requested. Anything else keeps the offer.
STAMP=0
case "$FILE" in
  "$HOME"/Documents/deep-research/*.html) STAMP=1;;
  # And the agent hubs, since 01 Sep. Same argument as the HQ, and it was
  # always the same argument: a page at ~/Documents/agents/<id>/ is written
  # BY an agent INTO its own hub directory, which is Robert's private reading
  # archive by construction and can never be a client deliverable. The
  # asymmetry that justifies judgment elsewhere (a missing footer is a shrug,
  # a footer on a client deck is a disaster) simply does not exist here.
  #
  # Leaving it as an offer meant it depended on the agent remembering, and
  # this file already knows how that ends: "A contract that depends on
  # remembering is not a contract." Robert, 01 Sep, on a Codex page with no
  # footer: "they're still missing that hub footer". The Claude pages from the
  # same afternoon were missing it too, including four this session wrote. Not
  # a Codex bug at all, a gap in the zone that both harnesses fell into.
  #
  # index.html never reaches here: the hub itself is written by the app and is
  # already excluded above.
  "$HOME"/Documents/agents/*/*.html) STAMP=1;;
esac

# The META stamp is WIDER than the footer, on purpose.
#
# A footer is a courtesy to a human who found the page later. The session meta
# is the archive's author column, and it has to live IN the file because the
# file travels: into the index, into a static site, onto a public domain. A
# path can be read here and nowhere else, so a page that leaves this Mac
# without the stamp can never be attributed again.
#
# Both of Robert's own trees get it. The hub itself does not: the app writes
# that file every turn and owns its head. The comparison is exact rather than a
# glob, because `case` patterns match across slashes, so any pattern loose
# enough to name the hub also names every report brief filed under an agent.
META=0
case "$FILE" in
  "$HOME"/Documents/deep-research/*.html) META=1;;
  "$HOME"/Documents/agents/*.html)        META=1;;
esac
[ "$FILE" = "$HOME/Documents/agents/$SHORT/index.html" ] && META=0

python3 - "$FILE" "$LINK_SESSION" "$SHORT" "$TODAY" "$STAMP" "$TITLE" "$META" "$MISFILED" <<'PY' 2>/dev/null || true
import html as htmllib
import json, re, sys

path, session, short, today, stamp = sys.argv[1:6]
title = sys.argv[6] if len(sys.argv) > 6 else ""
meta = sys.argv[7] if len(sys.argv) > 7 else "0"
# The directory this page was written into, when it is NOT the writer's own.
misfiled = sys.argv[8] if len(sys.argv) > 8 and sys.argv[8] != "-" else ""

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
# COLOURS THE PAGE CHOOSES, NOT COLOURS WE GUESS.
#
# This block hard-coded a light palette -- #8f8a7c text, #ddd8cc rules, a
# #5d5a51 "Open hub" link. On a light page that reads fine, which is why it
# shipped and why nobody noticed. On a DARK page it is close to invisible:
# measured on 2026-08-29 against a page on this app's own console surface
# (#2A2C28), "Open hub" came out around 2:1, under half the 4.5:1 floor.
#
# Two rules, and between them the footer stops guessing what it is sitting on:
#
#   TEXT inherits. `color:inherit` takes whatever the page set as its own ink,
#   which is BY DEFINITION legible against that page's own background. Size,
#   not colour, is what makes it read as a footer -- 12.5px against the page's
#   body copy. No hue is ever chosen here, so no page can be dark or light
#   enough to break it.
#
#   RULES are neutral and translucent. Mid-grey at 42% shows against both a
#   near-white and a near-black ground without going garish on either, which a
#   fixed #ddd8cc could not do in one direction or a fixed #333 in the other.
#
# Deliberately NOT opacity on the footer element. Opacity composites the whole
# subtree and a child cannot opt out -- `opacity:1` on the button inside an
# `opacity:.78` parent still renders at .78 -- so dimming the meta line that
# way would have quietly washed out the one control that carries its own
# contrast. "Discuss with agent" keeps its solid background and white ink:
# 8.6:1 wherever it lands, owing the page nothing.
# IT HAS TO LAND IN THE TEXT COLUMN.
#
# The stamp goes in before </body>, which on almost every page in this archive
# is OUTSIDE the container the article lives in — a <div class="wrap"> with a
# max-width and side padding. So the footer rendered full-bleed and hard against
# the left edge of the window while the article sat centred in the middle of it:
# on a wide window at low zoom it reads as a stray strip of text belonging to
# nothing, and Robert reported the page as having no footer at all (03 Sep).
#
# It cannot know the container's name, so it stops depending on one. Centring
# itself at the same 860px the pages use puts it under the column whether it
# lands inside the wrapper or after it, and no side padding keeps it flush with
# the text in the inside case.
snippet = (
    '<footer data-tb-agent="{short}" style="box-sizing:border-box;'
    'max-width:860px;margin:64px auto 0;padding:20px 0 0;'
    'border-top:1px solid rgba(128,128,128,.42);'
    'font:12.5px/1.5 ui-monospace,Menlo,monospace;color:inherit;'
    'display:flex;flex-wrap:wrap;gap:10px;align-items:center">\n'
    '  <div style="flex:1;min-width:220px">{who}</div>\n'
    '  <a href="file://{hub}" '
    'style="text-decoration:none;color:inherit;border:1px solid rgba(128,128,128,.5);'
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

# ---------------------------------------------------------------------------
# TAG IT (judged, but asked EVERY time).
#
# A tag is the one field on a page that a machine cannot fill honestly. The
# session id is a fact the hook holds; the footer is a fixed string; the brand
# can be inferred from siblings. The SUBJECT is a reading, and the attempt to
# derive one from keywords was built and thrown away on 02 Sep for being
# confidently wrong ("Three open PRs" -> voice-and-audio).
#
# So the hook does the two things it CAN do, on every page written into either
# of Robert's trees: it notices the page has no tags, and it hands over the
# vocabulary the archive already uses, at the moment the writer still has the
# page in mind. The SessionStart context said the same thing once, at turn 0,
# and 1,020 of 1,110 pages were written without tags anyway. A contract that
# depends on remembering is not a contract; this one asks again every time.
#
# It stays an instruction rather than a block: PostToolUse cannot stop a Write
# that already happened, and a page with no tags is still a page worth keeping.
def _vocab():
    """What the archive already calls things. Same source as hq-tags."""
    import os
    paths = []
    try:
        sys.path.insert(0, os.path.expanduser("~/.claude/skills/research-hq/scripts"))
        from hqconfig import roots
        paths.append(str(roots.out / "tags.json"))
    except Exception:
        pass
    paths.append(os.path.expanduser("~/Projects/intranet/tags.json"))
    for candidate in paths:
        try:
            with open(candidate, encoding="utf-8") as fh:
                return [row[0] for row in json.load(fh)][:36]
        except Exception:
            continue
    return []


def _tag_ask(path):
    if meta != "1" and stamp != "1":
        return ""                      # not in the archive, not indexed, not asked
    try:
        with open(path, "r", encoding="utf-8") as fh:
            page = fh.read(60000)
    except Exception:
        return ""
    want = [f for f in ("tags", "summary")
            if not re.search(r'<meta\s+name="intranet:%s"' % f, page)]
    if not want:
        return ""
    vocab = _vocab()
    ask = (
        "\n\nTAG IT. This page declares no intranet:{missing}, so in the index it is "
        "findable only by whoever remembers the day it was written. Add these lines to "
        "the head of {path} now, before you finish the turn:\n\n"
        '  <meta name="intranet:tags" content="a, b, c">\n'
        '  <meta name="intranet:summary" content="one sentence saying what this page '
        'concluded">\n\n'
        "Two to four tags, lowercase kebab-case, naming the SUBJECT — never the brand "
        "and never the document type, both of which are already their own fields. "
        "REUSE a term the archive has rather than coining a synonym for it."
    ).format(missing=" or intranet:".join(want), path=path)
    if vocab:
        ask += (" These are the ones in use, most used first:\n  "
                + ", ".join(vocab)
                + "\n(`hq-tags` prints the full list; `hq-tags <word>` searches it.)")
    return ask


TAG_ASK = _tag_ask(path)

# A misfile is louder than anything else this hook says, because it is the one
# failure that makes the archive assert something untrue about who did the work.
MISFILE_ASK = ("\n\nWRONG DIRECTORY. You wrote this page into agent {other}'s hub "
               "directory, and it is not yours. Your pages belong in "
               "~/Documents/agents/{mine}/ — the first eight characters of YOUR "
               "session id, nothing else.\n\nMove it now:\n"
               "  mv {path} ~/Documents/agents/{mine}/\n\n"
               "Left where it is, the archive says {other} wrote it: that agent's "
               "hub lists it, its footer names {other}, and Discuss with agent "
               "opens the wrong conversation. Two pages did exactly this on "
               "02 Sep and both hubs claimed them."
               ).format(other=misfiled, mine=short, path=path) if misfiled else ""

if meta == "1":
    # The author column, written by the only thing that knows it.
    #
    # Declared beats inferred, always: if the page already names a session the
    # hook leaves it alone, exactly like the indexer's precedence chain. Only
    # `session` is stamped. `updated` is deliberately NOT, because the footer
    # path below preserves the file's mtime on purpose and the indexer derives
    # `updated` from that mtime, so a stamped copy would be a second source of
    # truth for a fact already kept correctly. `turn` is not stamped either:
    # this hook does not know the turn ordinal, and three earlier mechanisms in
    # this codebase failed by working a fact out of something adjacent. The app
    # knows turns; the stamp can wait for the thing that does.
    try:
        with open(path, "r", encoding="utf-8") as fh:
            page = fh.read()
        if not re.search(r'<meta\s+name="intranet:session"', page):
            tag = '<meta name="intranet:session" content="{}">'.format(short)
            if "</head>" in page:
                h, _, t = page.partition("</head>")
                out = h + "  " + tag + "\n</head>" + t
            elif re.search(r"<body\b", page):
                out = re.sub(r"(<body\b)", tag + "\n\\1", page, count=1)
            else:
                out = tag + "\n" + page
            import os as _os
            before = _os.stat(path)
            tmp = path + ".tb-meta"
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(out)
            _os.replace(tmp, path)
            _os.utime(path, (before.st_atime, before.st_mtime))
    except Exception:
        pass

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
        ).format(path=path) + MISFILE_ASK + TAG_ASK,
    }}))
else:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": context + MISFILE_ASK + TAG_ASK,
    }}))
PY

exit 0
