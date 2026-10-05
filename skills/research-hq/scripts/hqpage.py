#!/usr/bin/env python3
"""Start a page on the template, in the right place, with the right tokens.

    hq-page new <slug> --session=<full session id> [--brand=NAME] [--title="..."]
    hq-page publish <slug> --session=<full session id>

A NEW PAGE STARTS AS A DRAFT (29 Sep 2026). `new` writes the scaffold to
<hub>/_drafts/<slug>.html, and `publish` moves the finished page to
<hub>/<slug>.html and opens it. The mirror and every door skip names that
start with `_`, so nothing can publish, announce or open a page before the
agent has filled it. Before this, `new` wrote the empty template straight to
the page's own address; one agent scaffolded, then waited on a deploy, and
the app announced the empty template to Robert in the Hub window ("still
getting empty reports, THIS MUST NEVER HAPPEN").

The command supplies the current markup and rules at creation, and checks
publication before moving the file. Reading a template into a shell variable
is not evidence that its contents reached the authoring model; the output
therefore explicitly requires a visible read before writing.

The session id is REQUIRED and taken from the command line, never guessed:
the shell a session runs in carries no session id, and the SessionStart text
already names the full id, so the agent has it. Guessing from cwd is how pages
land on the wrong hub.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from html.parser import HTMLParser

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent.parent / "share-as-page"
TEMPLATE = SKILL / "templates" / "brief.html"
BRIEF = SKILL / "references" / "brief.md"
HQ_THEME = HERE / "hqtheme.py"


def agents_root():
    """Exactly what `hq-root agents` answers: one resolver, honouring HQ_CONFIG."""
    try:
        out = subprocess.run([sys.executable, str(HERE / "hqconfig.py"), "agents"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        if out.startswith("/"):
            return Path(out)
    except Exception:
        pass
    return Path.home() / "Documents" / "agents"


def usage(code=2):
    print("usage: hq-page new <slug> --session=<full session id> [--brand=NAME] [--title=\"...\"]\n"
          "       hq-page publish <slug> --session=<full session id>", file=sys.stderr)
    return code


class PageStructure(HTMLParser):
    """Parse real elements, so escaped examples and comments are not violations."""
    def __init__(self):
        super().__init__()
        self.disclosures = []

    def handle_starttag(self, tag, attrs):
        if tag == "details":
            self.disclosures.append(self.getpos()[0])

    handle_startendtag = handle_starttag


def structure_errors(page):
    parser = PageStructure()
    parser.feed(page)
    return [f"line {line}: <details> can hide evidence, even with open. "
            'Use <section class="claim" data-shows="TYPE"> with a <div class="head">; '
            "replace </summary> and </details> accordingly."
            for line in parser.disclosures]


def publish(session, slug):
    """Move a filled draft to its address and open it.

    It refuses a draft that still carries the scaffold's own markers: an
    attribute left as FILL means the page was never filled, and publishing it
    is the one failure this command exists to prevent.
    """
    hub = agents_root() / session
    draft, out = hub / "_drafts" / f"{slug}.html", hub / f"{slug}.html"
    if not draft.exists():
        print(f"hq-page: no draft at {draft}; start one with `hq-page new {slug} --session={session}`.",
              file=sys.stderr)
        return 1
    page = draft.read_text(encoding="utf-8")
    errors = structure_errors(page)
    if errors:
        print("hq-page: publication stopped; the draft is unchanged.\n" + "\n".join(errors), file=sys.stderr)
        return 1
    left = re.findall(r'="FILL[^"]*"|base64,FILL', page)
    if left:
        print(f"hq-page: {draft} is not filled yet ({len(left)} placeholder(s) left, e.g. {left[0]}). "
              "Fill it, then publish.", file=sys.stderr)
        return 1
    draft.replace(out)
    print(out)
    subprocess.run([sys.executable, str(HERE / "hq-open"), str(out)])
    return 0


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    opts = {}
    for a in argv[1:]:
        if a.startswith("--") and "=" in a:
            k, v = a[2:].split("=", 1)
            opts[k] = v
        elif a.startswith("--"):
            print(f"hq-page: use {a}=VALUE", file=sys.stderr)
            return 2
    if len(args) != 2 or args[0] not in ("new", "publish"):
        return usage()
    slug = args[1]
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,60}", slug):
        print("hq-page: a slug is lowercase letters, digits and hyphens, e.g. uvape-what-changed",
              file=sys.stderr)
        return 2
    session = (opts.get("session") or "").strip().lower()
    if not re.fullmatch(r"[0-9a-f-]{32,36}", session):
        print("hq-page: --session=<your full session id> is required. It is the id in your "
              "SessionStart context and in your scratchpad path; never another agent's.",
              file=sys.stderr)
        return 2
    if args[0] == "publish":
        return publish(session, slug)
    if not TEMPLATE.exists():
        print(f"hq-page: template missing at {TEMPLATE}", file=sys.stderr)
        return 1

    live = agents_root() / session / f"{slug}.html"
    if live.exists():
        print(f"hq-page: {live} exists; pick another slug or edit that file.", file=sys.stderr)
        return 1
    out_dir = agents_root() / session / "_drafts"
    out = out_dir / f"{slug}.html"
    if out.exists():
        print(f"hq-page: a draft is already at {out}; fill it, or pick another slug.", file=sys.stderr)
        return 1

    # Tokens from hq-theme. With --brand this BINDS the session to the brand,
    # exactly as `hq-theme <session> --brand=NAME` does, so every later page
    # resolves the same brand from the id alone.
    cmd = [sys.executable, str(HQ_THEME), session]
    brand = opts.get("brand")
    if brand:
        cmd.append(f"--brand={brand}")
    theme = subprocess.run(cmd, capture_output=True, text=True)
    if theme.returncode != 0:
        print(f"hq-page: hq-theme failed: {theme.stderr.strip()}", file=sys.stderr)
        return 1
    tokens = theme.stdout.strip()
    header = tokens.splitlines()[0] if tokens else ""
    nameplate = header[len("/* "):].split(" · ")[0].strip() if header.startswith("/* ") else "Tranquility Base"

    page = TEMPLATE.read_text(encoding="utf-8")
    # The :root block(s) between the TOKENS comment and the HOUSE CONSTANTS comment
    # are replaced by hq-theme's output; the constants stay.
    start = page.index("/* TOKENS.")
    end = page.index("/* HOUSE CONSTANTS")
    page = page[:start] + "/* TOKENS from hq-theme, " + time.strftime("%Y-%m-%d") + " */\n" + tokens + "\n" + page[end:]
    page = page.replace('<meta name="intranet:session" content="FILL: FULL SESSION ID">',
                        f'<meta name="intranet:session" content="{session}">')
    today = time.strftime("%-d %b %Y")
    page = page.replace("<!-- KICKER: two items, brand and date. Nothing else. -->",
                        f"{nameplate} · {today}")
    if brand:
        page = page.replace('<meta name="intranet:brand" content="FILL: BRAND">',
                            f'<meta name="intranet:brand" content="{brand}">')
    title = opts.get("title")
    if title:
        page = page.replace("<title><!-- TITLE: two to five words, the message, not the topic --></title>",
                            f"<title>{title}</title>")
        page = page.replace("<h1><!-- TITLE: the one sentence they cannot miss. A finding with a verb, not a topic. --></h1>",
                            f"<h1>{title}</h1>")

    out_dir.mkdir(parents=True, exist_ok=True)
    out.write_text(page, encoding="utf-8")
    fallback = " (no theme on record for that brand: house tokens, say so in one line)" if "NO THEME ON RECORD" in header else ""
    print(f"{out}")
    print(f"tokens: {header.strip('/* ').strip(' */')}{fallback}")
    print('Claims must use <section class="claim" data-shows="TYPE">; never <details>, even with open.')
    print(f"Before writing, READ {BRIEF} and {out} in a separate tool call that returns their contents. "
          "Do not redirect this output or combine new, writing and publish in one call.")
    print('Example: <section class="claim" data-shows="text"><div class="head">The claim.</div>'
          '<div class="d"><pre>The literal evidence.</pre></div></section>')
    print(f"This is a DRAFT: nothing publishes or opens it. Fill it here: one sentence at headline "
          f"size, the dark needs-you block, one row per claim with its artifact under it (rules: {BRIEF}). "
          f"When it is finished, run: hq-page publish {slug} --session={session}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
