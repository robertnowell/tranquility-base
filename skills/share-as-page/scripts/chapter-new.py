#!/usr/bin/env python3
"""chapter-new <slug> --session=<id> --series="Name" --chapter=N [--brand=NAME] [--title="..."]
Writes <hub>/<session>/_drafts/<slug>.html from templates/chapter.html with the session's theme tokens."""
import os, re, subprocess, sys, time
from pathlib import Path
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
TEMPLATE = HERE / "chapter.html"
HQ_THEME = "hq-theme"

def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in argv[1:] if a.startswith("--") and "=" in a)
    if len(args) != 1 or not opts.get("session") or not opts.get("series") or not opts.get("chapter"):
        print(__doc__, file=sys.stderr); return 2
    slug, session = args[0], opts["session"]
    root = Path(os.environ.get("TB_AGENTS_ROOT") or Path.home() / "Documents" / "agents") / session
    out = root / "_drafts" / f"{slug}.html"
    if (root / f"{slug}.html").exists() or out.exists():
        print(f"chapter-new: {slug} exists; pick another slug", file=sys.stderr); return 1
    cmd = [HQ_THEME, session] + ([f"--brand={opts['brand']}"] if opts.get("brand") else [])
    theme = subprocess.run(cmd, capture_output=True, text=True)
    if theme.returncode != 0:
        print(theme.stderr, file=sys.stderr); return 1
    tokens = theme.stdout.strip(); header = tokens.splitlines()[0]
    nameplate = header[3:].split(" · ")[0].strip() if header.startswith("/* ") else "Tranquility Base"
    page = TEMPLATE.read_text(encoding="utf-8")
    start, end = page.index("/* TOKENS."), page.index("/* HOUSE CONSTANTS")
    page = page[:start] + "/* TOKENS from hq-theme, " + time.strftime("%Y-%m-%d") + " */\n" + tokens + "\n" + page[end:]
    page = page.replace('content="FILL: FULL SESSION ID"', f'content="{session}"')
    page = page.replace('content="FILL: the series name"', f'content="{opts["series"]}"').replace('content="FILL: N"', f'content="{opts["chapter"]}"')
    if opts.get("brand"): page = page.replace('content="FILL: BRAND"', f'content="{opts["brand"]}"')
    page = page.replace("<!-- KICKER: series · chapter N · brand · date · N words -->",
                        f"{opts['series']} · Chapter {opts['chapter']} · {nameplate} · {time.strftime('%-d %b %Y')}")
    if opts.get("title"):
        page = page.replace("<title><!-- TITLE: the thesis, under ten words --></title>", f"<title>{opts['title']}</title>")
    out.parent.mkdir(parents=True, exist_ok=True); out.write_text(page, encoding="utf-8")
    print(out); print(f"tokens: {header.strip('/* ').strip(' */')}")
    print(f"Read {HERE/'chapter.md'} and the draft before writing. Audit with chapter-audit, then: hq-page publish {slug} --session={session}")
    return 0
if __name__ == "__main__": sys.exit(main(sys.argv))
