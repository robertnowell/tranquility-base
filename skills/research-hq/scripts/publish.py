#!/usr/bin/env python3
"""research-hq — index and publish everything you've researched and written.

One deterministic pass, no LLM:

1. Normalize the HQ root into the canonical layout `<date-slug>/report.md`,
   leaving symlinks at any legacy flat paths so old references still resolve.
2. Render `report.html` (pandoc, house editorial style) for every report that
   has none. Never overwrites HTML it didn't generate (marker at byte 0).
3. Collect declared metadata — markdown frontmatter, `<meta name="intranet:*">`
   tags, `meta.json` — falling back to keyword inference only where nothing is
   declared.
4. Emit `catalog.json` + a searchable `index.html` (the private index).
5. With --deploy: copy the `visibility: hosted` subset into one static site and
   push it to a host. URLs are deterministic: `<base>/<slug>/`.

Zero-config works: with no config file it indexes ~/Documents/deep-research
into ~/research-hq. Everything machine-specific lives in the config file, so
this same script runs unmodified on any machine.

  publish.py                 build the local index
  publish.py --deploy        also sync + deploy the hosted subset
  publish.py --init          write a starter config you can edit
  publish.py --config PATH   use a specific config file

Config resolution: --config → $HQ_CONFIG → ~/.claude/hq.json → built-in defaults.
"""

import argparse
import html as htmllib
import json
from collections import Counter
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

SKILL_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from hqconfig import roots  # noqa: E402  (needs SKILL_DIR on the path first)

DATED = re.compile(r"^(\d{4}-\d{2}-\d{2})-(.+)$")
# An agent directory is named for its session: hex, with dashes tolerated
# because the harness sometimes hands over a full UUID.
SESSION_DIR = re.compile(r"^[0-9a-fA-F][0-9a-fA-F-]{3,63}$")

# Written at byte 0 of generated HTML so we only ever regenerate our own output.
# Older installs wrote the second form; both are recognized, the first is written.
MARKERS = ("<!-- research-hq-generated -->", "<!-- intranet-generated -->")
MARKER = MARKERS[0]

# Declared metadata carriers, weakest → strongest:
# keyword inference → path → report.md frontmatter → <meta name="intranet:*"> → meta.json
#
# The six after `url` were added when the archive gained an author. `session` is
# the join that turns an index into a workbook; `turn` anchors a page to the
# conversation that made it; `origin` says what produced it, so a consumer can
# require the real deep-research pipeline rather than trusting a typed
# `type: research`; `summary` is a declared sentence four consumers were each
# scraping differently; `supersedes` was already being WRITTEN into report
# frontmatter and silently dropped here for want of a list entry; `updated` is
# not `date`, and a page rewritten eight times needs both.
# An index is not an artifact.
#
# The artifact hook records HTML a session writes, and it globs the trees pages
# are built in — which includes wherever this script puts the index. Two
# sessions had the private index recorded as a page they made on 02 Sep. No path
# rule can fix it (the root is configurable), so the file says what it is on its
# first line and the hook skips it.
MARK = "<!-- research-hq-generated: index -->\n"

META_FIELDS = ("title", "brand", "type", "question", "status", "visibility", "tags", "url",
               "session", "turn", "origin", "summary", "supersedes", "updated")

DEFAULTS = {
    "hq_root": "~/Documents/deep-research",
    "out_dir": "~/research-hq",
    "title": "Research HQ",
    "template": None,                 # defaults to the skill's templates/index.html
    "host": {
        "provider": "vercel",         # vercel | command | none
        "base_url": None,             # stable alias; learned on first deploy
        "deploy_cmd": None,           # provider=command: run inside the built site dir
        "robots": "disallow",         # disallow | allow
    },
    "scan": {
        "page_roots": [],             # dirs whose <slug>/index.html are page deliverables
        "extra_page_dirs": [],        # dirs that are deliverables but lack the -page suffix
        "exclude_dirs": [],
        "extra_html_globs": [],       # globs (relative to each page root) for loose HTML
        "episode_roots": [],          # [{"path": ..., "brand": ..., "exclude": [...]}]
    },
    "brand_rules": [],                # [["keyword", "Brand"], ...] first match wins
    # Where extracted media lives once it stops living inside the HTML.
    #
    # Every page in this archive has been required to be FULLY self-contained,
    # which is what makes one portable and what makes it enormous: 72 of 1756
    # pages hold inline images, and those 72 carry 94.6 MB -- 35% of all the
    # HTML on disk. Four pages alone are 75 MB of base64.
    #
    # base_url stays None until a bucket actually exists, and None means the
    # old rule is still in force everywhere: check-brand.sh keeps failing any
    # external subresource, and nothing is rewritten. Setting it is the single
    # switch that opens the door, so the door cannot be opened by accident.
    "assets": {
        "base_url": None,             # e.g. "https://assets.example.com/hq"
        "provider": None,             # r2 | s3 | none
        "bucket": None,
        "endpoint": None,             # S3-compatible endpoint for provider=r2
        "prefix": "media",            # key prefix inside the bucket
    },
}


# ------------------------------------------------------------------ config
def deep_merge(base, over):
    out = dict(base)
    for k, v in (over or {}).items():
        out[k] = deep_merge(base[k], v) if isinstance(v, dict) and isinstance(base.get(k), dict) else v
    return out


def load_config(explicit=None):
    path = explicit or os.environ.get("HQ_CONFIG") or (Path.home() / ".claude" / "hq.json")
    path = Path(path).expanduser()
    if not path.exists():
        return deep_merge(DEFAULTS, {}), None
    try:
        return deep_merge(DEFAULTS, json.loads(path.read_text())), path
    except (json.JSONDecodeError, OSError) as e:
        sys.exit(f"research-hq: cannot read config {path}: {e}")


def P(p):
    return Path(str(p)).expanduser()


class HQ:
    """Resolved configuration + derived paths."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.root = P(cfg["hq_root"])
        self.assets = cfg.get("assets") or {}
        self.out = P(cfg["out_dir"])
        self.site = self.out / "site"          # built static site (hosted subset)
        self.url_file = self.out / "base-url.txt"
        self.title = cfg.get("title") or "Research HQ"
        self.brand_rules = [tuple(r) for r in cfg.get("brand_rules", []) if len(r) == 2]
        self.scan = cfg["scan"]
        self.host = cfg["host"]
        tpl = cfg.get("template")
        self.template = P(tpl) if tpl else SKILL_DIR / "templates" / "index.html"

    def infer_brand(self, *texts):
        hay = " ".join(t.lower() for t in texts if t)
        for kw, brand in self.brand_rules:
            if kw in hay:
                return brand
        return "Unfiled"

    def assets_base_url(self):
        """The origin extracted media is served from, or None if unconfigured.

        None is the safe default and means "nothing has changed": the
        self-containment rule stays absolute and no page may reference an
        outside image. Everything downstream reads this one value, so there
        is exactly one place to look when asking whether the archive is
        allowed to point outward yet.
        """
        u = (self.assets or {}).get("base_url")
        return u.rstrip("/") if u else None

    def base_url(self):
        cfg_base = (self.host or {}).get("base_url")
        if cfg_base:
            return cfg_base.rstrip("/")
        if self.url_file.exists():
            return self.url_file.read_text().strip().rstrip("/")
        return None


# ------------------------------------------------------------------ helpers
def have(cmd):
    return shutil.which(cmd) is not None


def parse_html_meta(head):
    """Declared `intranet:*` metas, in EITHER attribute order.

    The Swift side reads both orders and its comment says why: hand-written
    pages put `name` first, pandoc puts `content` first, and a single-order
    pattern "silently returned nothing for a third of the pages". This side
    read `name`-first only, so the two halves of the system disagreed about
    what a page had declared -- no error, nothing in any log.
    """
    out = {}
    pairs = []
    for m in re.finditer(r'<meta\s+name="intranet:(\w+)"\s+content="([^"]*)"', head, re.I):
        pairs.append((m.group(1), m.group(2)))
    for m in re.finditer(r'<meta\s+content="([^"]*)"\s+name="intranet:(\w+)"', head, re.I):
        pairs.append((m.group(2), m.group(1)))
    for k, raw in pairs:
        v = htmllib.unescape(raw)
        if k in META_FIELDS and v and k not in out:
            out[k] = [t.strip() for t in v.split(",")] if k == "tags" else v
    return out

def parse_frontmatter(md_path):
    """Leading ---fenced key: value block. Flat scalars only; unknown keys ignored."""
    try:
        text = md_path.read_text(errors="replace")
    except OSError:
        return {}
    m = re.match(r"\s*---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}
    out = {}
    for line in m.group(1).splitlines():
        km = re.match(r"^(\w+):\s*(.+?)\s*$", line)
        if km and km.group(1) in META_FIELDS:
            k, v = km.group(1), km.group(2).strip("\"'")
            out[k] = [t.strip() for t in v.split(",")] if k == "tags" else v
    return out


def apply_declared(item, *sources):
    for src in sources:
        for k, v in src.items():
            if v:
                item[k] = v
    return item


def md_title(md_path):
    try:
        for line in md_path.read_text(errors="replace").splitlines()[:40]:
            m = re.match(r"^#\s+(.+)", line.strip())
            if m:
                return re.sub(r"[*_`]", "", m.group(1)).strip()
    except OSError:
        pass
    return None


def html_title(path, head=None):
    try:
        head = head if head is not None else path.read_text(errors="replace")[:20000]
    except OSError:
        return None
    m = re.search(r"<title>(.*?)</title>", head, re.S)
    return htmllib.unescape(m.group(1).strip()) if m else None


def slug_title(slug):
    return slug.replace("-", " ").strip().title()


def blank_item(**kw):
    base = {"type": "research", "title": "", "date": "", "slug": "", "brand": "Unfiled",
            "question": "", "status": "", "visibility": "local", "tags": [],
            "html": None, "md": None, "url": None,
            "session": "", "turn": "", "origin": "", "summary": "",
            "supersedes": "", "updated": ""}
    base.update(kw)
    return base


# ------------------------------------------------------------- 1. normalize
def normalize(hq, log):
    if not hq.root.is_dir():
        return
    for f in sorted(hq.root.iterdir()):
        if f.is_symlink() or not f.is_file() or f.suffix not in (".md", ".html"):
            continue
        if not DATED.match(f.stem):
            continue
        d = hq.root / f.stem
        d.mkdir(exist_ok=True)
        target = d / ("report.md" if f.suffix == ".md" else "report.html")
        if target.exists():
            log.append(f"skip (target exists): {f.name}")
            continue
        f.rename(target)
        # NO SYMLINK. This used to leave one at the flat path so old references
        # kept resolving, and that compatibility shim became a second home for
        # the archive: 1,057 links, and the reason the retired root could never
        # be deleted — every run rebuilt it (#267). The references have been
        # rewritten to the real paths instead, which is the fix the shim was
        # deferring. A link that has to be rewritten once is cheaper than a
        # directory tree that has to be maintained forever.
        log.append(f"moved {f.name} -> {f.stem}/{target.name}")


# ------------------------------------------------------------- 2. render
PANDOC_CSS = """
:root { --ikb:#002FA7; --ink:#1B1D22; --paper:#F7F3E8; --stone:#6E6C60; --rule:#CDC7B8; }
html { background: var(--paper); }
body { max-width: 68ch; margin: 0 auto; padding: 4rem 1.5rem 6rem;
  font: 18px/1.65 Charter, Georgia, serif; color: var(--ink); }
h1,h2,h3,h4 { font-family: Charter, Georgia, serif; line-height:1.2; letter-spacing:-0.01em; }
h1 { font-size: 2.1rem; margin: 0 0 .3em; }
h1:after { content:""; display:block; width:3.5rem; border-bottom:3px solid var(--ikb); margin-top:.4em; }
h2 { font-size: 1.4rem; margin-top: 2.2em; border-bottom: 1px solid var(--rule); padding-bottom:.25em; }
h3 { font-size: 1.1rem; margin-top: 1.8em; }
a { color: var(--ikb); }
code, pre { font-family: "Berkeley Mono", ui-monospace, SFMono-Regular, Menlo, monospace; font-size:.85em; }
pre { background:#EDE6D3; padding: .9em 1em; overflow-x:auto; border-left:3px solid var(--rule); }
blockquote { margin:1.5em 0; padding:.1em 1.2em; border-left:3px solid var(--ikb); color:var(--stone); }
table { border-collapse: collapse; width:100%; font-size:.9em; }
th, td { text-align:left; padding:.45em .7em; border-bottom:1px solid var(--rule); vertical-align:top; }
th { font-family:-apple-system, "Helvetica Neue", sans-serif; font-size:.75em;
  text-transform:uppercase; letter-spacing:.08em; color:var(--stone); }
img { max-width:100%; }
hr { border:0; border-top:1px solid var(--rule); margin:2.5em 0; }
@media print { body { padding:0; font-size:11pt; } }
"""


def pandoc_render(md, out, title, has_h1):
    """md → standalone HTML. Returns (ok, error). Retries without YAML parsing,
    which is the common failure on reports whose frontmatter isn't valid YAML."""
    # with its own H1, pass pagetitle only so pandoc doesn't render a duplicate title block
    targ = ["--metadata", f"{'pagetitle' if has_h1 else 'title'}={title}"]
    payload = f"{MARKER}\n<style>{PANDOC_CSS}</style>"
    for extra in ([], ["-f", "markdown-yaml_metadata_block"]):
        r = subprocess.run(["pandoc", str(md), *extra, "-s", "-H", "/dev/stdin", *targ,
                            "-o", str(out)], input=payload, text=True, capture_output=True)
        if r.returncode == 0:
            out.write_text(MARKER + "\n" + out.read_text(errors="replace"))
            return True, None
        if "YAML" not in r.stderr:
            break
    return False, r.stderr.strip()[:160]


def is_ours(path):
    try:
        return any(m in path.read_text(errors="replace")[:200] for m in MARKERS)
    except OSError:
        return False


def render_reports(hq, log):
    if not hq.root.is_dir():
        return
    if not have("pandoc"):
        log.append("pandoc not installed — skipping HTML rendering "
                   "(install: brew install pandoc / apt install pandoc)")
        return
    rendered = failed = 0
    for d in sorted(hq.root.iterdir()):
        md = d / "report.md"
        if not d.is_dir() or not md.exists():
            continue
        existing = next((p for p in (d / "report.html", d / "index.html") if p.exists()), None)
        if existing and (not is_ours(existing) or md.stat().st_mtime <= existing.stat().st_mtime):
            continue
        title = md_title(md)
        ok, err = pandoc_render(md, existing or (d / "report.html"),
                                title or slug_title(DATED.sub(r"\2", d.name)), bool(title))
        if ok:
            rendered += 1
        else:
            failed += 1
            log.append(f"pandoc failed {d.name}: {err}")
    log.append(f"rendered {rendered} report HTML file(s) ({failed} failure(s))")


# ------------------------------------------------------------- 3. collect
def _mtime(*paths):
    ts = [p.stat().st_mtime for p in paths if p is not None and p.exists()]
    return datetime.fromtimestamp(max(ts)).strftime("%Y-%m-%d") if ts else ""


def report_item(hq, d, session=""):
    """One report directory to one record, or None if it holds neither document.

    Extracted from collect_reports so that a report filed under its agent and a
    report in the legacy corpus produce the SAME record. The shape of a research
    report (a dated directory holding report.md beside index.html) is the part
    that must not change when the parent does; that is the whole reason the
    migration is a field and not a rewrite.
    """
    m = DATED.match(d.name)
    date, slug = (m.group(1), m.group(2)) if m else (None, d.name)
    md = d / "report.md"
    html = next((p for p in (d / "report.html", d / "index.html") if p.exists()), None)
    if not md.exists() and not html:
        return None
    head = ""
    if html:
        try:
            head = html.read_text(errors="replace")[:20000]
        except OSError:
            head = ""
    title = (md_title(md) if md.exists() else None) or html_title(html, head) or slug_title(slug)
    item = blank_item(
        type="research", title=title, slug=d.name,
        date=date or datetime.fromtimestamp(d.stat().st_mtime).strftime("%Y-%m-%d"),
        brand=hq.infer_brand(d.name, title), session=session,
        updated=_mtime(md, html),
        html=str(html) if html else None, md=str(md) if md.exists() else None)
    fm = parse_frontmatter(md) if md.exists() else {}
    mj = {}
    meta = d / "meta.json"
    if meta.exists():
        try:
            mj = json.loads(meta.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return apply_declared(item, fm, parse_html_meta(head), mj)


def collect_agent_pages(hq):
    """Everything a session wrote, filed under the agent that wrote it.

    Ninety-five pages lived here and appeared in no index, because the scanner
    only knew about the research corpus. They were reachable only by already
    knowing the agent id, which is the opposite of what an index is for.

    The session is read off the DIRECTORY when the page does not declare one.
    That is not a guess dressed as a fact: an agent directory is named for its
    session, so the path is a carrier of the record, weaker than a stamp and
    stronger than nothing. It is also what makes the 95 orphans resolve on the
    first run, before a single hook has been changed, and it is why the archive
    directory (whose reports have no known author) simply carries no session
    rather than being given a wrong one.
    """
    items, root = [], roots.agents
    if not root.is_dir():
        return items
    archive_name = roots.archive.name if roots.archive.parent == root else None
    for d in sorted(root.iterdir()):
        if d.is_symlink() or not d.is_dir():
            continue
        if d.name == archive_name:
            session = ""
        elif SESSION_DIR.match(d.name):
            session = d.name
        else:
            continue
        mine = []                                # this agent's records, filled together
        for sub in sorted(d.iterdir()):          # research reports keep their shape
            if sub.is_dir() and not sub.is_symlink():
                it = report_item(hq, sub, session=session)
                if it:
                    mine.append(it)
        for f in sorted(d.glob("*.html")):       # session output, one file per report
            # index.html is the hub itself, rewritten by the app every turn. It
            # is the address these pages hang off, never one of them.
            if f.is_symlink() or f.name == "index.html":
                continue
            try:
                head = f.read_text(errors="replace")[:20000]
            except OSError:
                head = ""
            title = html_title(f, head) or slug_title(f.stem)
            item = blank_item(
                type="page", title=title, slug=f.stem,
                date=_mtime(f), updated=_mtime(f),
                brand=hq.infer_brand(f.stem, title),
                session=session, origin="agent", html=str(f))
            mine.append(apply_declared(item, parse_html_meta(head)))
        items += _fill_brand_from_siblings(mine)
    return items


def _fill_brand_from_siblings(items):
    """An agent's own pages say what the agent is working on.

    Filename keywords are a poor brand signal for session output: a page called
    slot-visual-check.html matches no rule and lands as Unfiled, which is how
    adding 97 real pages made the index LOOK worse. The honest signal is next
    door. Where sibling pages under the same agent declare a brand, an
    undeclared one inherits the commonest of them.

    This is the rule HomeBase already applies in the other direction, and for
    the reason its comment records: a session fixing Tranquility Base out of a
    promotions checkout was themed Kopi by its directory while every page it
    wrote declared Tranquility Base. The artifacts are the honest signal. They
    are the thing the brand is FOR.

    Only 'Unfiled' is filled, so a declared brand and a keyword match both win.
    """
    declared = [i["brand"] for i in items if i["brand"] and i["brand"] != "Unfiled"]
    if not declared:
        return items
    # Deterministic on purpose. `max(set(...), key=count)` reads fine and is a
    # coin toss on ties, because set iteration order moves with the process hash
    # seed: two runs over identical files produced two different brands for the
    # same pages. An index that disagrees with itself between builds is worse
    # than one that guesses, because the disagreement is invisible.
    counts = {}
    for b in declared:
        counts[b] = counts.get(b, 0) + 1
    winner = min(counts, key=lambda b: (-counts[b], b))
    for i in items:
        if i["brand"] == "Unfiled":
            i["brand"] = winner
    return items


def collect_reports(hq):
    items = []
    if not hq.root.is_dir():
        return items
    for d in sorted(hq.root.iterdir()):
        if d.is_symlink() or not d.is_dir():
            continue
        it = report_item(hq, d)
        if it:
            items.append(it)
    for f in sorted(hq.root.glob("*.html")):        # legacy loose HTML at the root
        if f.is_symlink():
            continue
        try:
            head = f.read_text(errors="replace")[:20000]
        except OSError:
            head = ""
        item = blank_item(
            type="research", title=html_title(f, head) or slug_title(f.stem), slug=f.stem,
            date=datetime.fromtimestamp(f.stat().st_mtime).strftime("%Y-%m-%d"),
            brand=hq.infer_brand(f.stem), html=str(f))
        items.append(apply_declared(item, parse_html_meta(head)))
    return items


def collect_pages(hq):
    """<root>/<slug>/index.html deliverables: -page suffix, declared metadata,
    a PROVENANCE block, or an explicit include list."""
    items, scan = [], hq.scan
    extra = set(scan.get("extra_page_dirs", []))
    exclude = set(scan.get("exclude_dirs", []))
    for root in [P(r) for r in scan.get("page_roots", [])]:
        if not root.is_dir():
            continue
        for d in sorted(root.iterdir()):
            idx = d / "index.html"
            if not d.is_dir() or d.name in exclude or not idx.exists():
                continue
            try:
                head = idx.read_text(errors="replace")
            except OSError:
                continue
            declared = parse_html_meta(head[:20000])
            if not (d.name.endswith("-page") or d.name in extra
                    or declared or "PROVENANCE" in head[:20000]):
                continue
            bm = re.search(r"PROVENANCE\s*[—–-]+\s*brand:\s*([^\n(<]+)", head)
            url = None
            vp = d / ".vercel" / "project.json"
            if vp.exists():
                try:
                    url = "https://" + json.loads(vp.read_text())["projectName"] + ".vercel.app"
                except (json.JSONDecodeError, KeyError, OSError):
                    pass
            title = html_title(idx, head) or slug_title(d.name.removesuffix("-page"))
            item = blank_item(
                type="page", slug=d.name, title=title,
                date=datetime.fromtimestamp(idx.stat().st_mtime).strftime("%Y-%m-%d"),
                brand=bm.group(1).strip() if bm else hq.infer_brand(d.name, title),
                html=str(idx), url=url)
            items.append(apply_declared(item, declared))
    return items


def collect_extra_html(hq):
    """Loose deliverable HTML that doesn't follow the <slug>/index.html shape."""
    items, scan = [], hq.scan
    globs = scan.get("extra_html_globs", [])
    for root in [P(r) for r in scan.get("page_roots", [])]:
        if not root.is_dir():
            continue
        for pattern in globs:
            for f in root.glob(pattern):
                if not f.is_file() or f.name in ("index.html", "template.html"):
                    continue
                try:
                    head = f.read_text(errors="replace")[:20000]
                except OSError:
                    continue
                title = html_title(f, head) or slug_title(f.stem)
                item = blank_item(
                    type="page", slug=f.stem, title=title,
                    date=datetime.fromtimestamp(f.stat().st_mtime).strftime("%Y-%m-%d"),
                    brand=hq.infer_brand(str(f), title), html=str(f))
                items.append(apply_declared(item, parse_html_meta(head)))
    return items


def collect_episodes(hq, log):
    """Project trees whose research lives per-item rather than in HQ (e.g. a
    video-essay episode dir). One catalog entry per subdirectory."""
    items = []
    for spec in hq.scan.get("episode_roots", []):
        root = P(spec.get("path", ""))
        if not root.is_dir():
            continue
        brand = spec.get("brand", "Unfiled")
        skip = set(spec.get("exclude", []))
        title_file = spec.get("title_file", "TOPIC.md")
        doc = spec.get("doc", "packages.md")
        for d in sorted(root.iterdir()):
            if not d.is_dir() or d.name in skip:
                continue
            title = slug_title(re.sub(r"^\d+-", "", d.name))
            date = datetime.fromtimestamp(d.stat().st_mtime).strftime("%Y-%m-%d")
            tf = d / title_file
            if tf.exists():
                txt = tf.read_text(errors="replace")
                tm = re.search(r"^(?:Topic|title):\s*(.+)$", txt, re.M | re.I)
                if tm:
                    title = tm.group(1).strip().strip('"')
                dm = re.search(r"(\d{4}-\d{2}-\d{2})", txt)
                if dm:
                    date = dm.group(1)
            md = d / doc
            html = d / (Path(doc).stem + ".html")
            if md.exists() and not html.exists() and have("pandoc"):
                pandoc_render(md, html, title, has_h1=True)
            item = blank_item(
                type="episode", title=title, date=date, brand=brand, slug=d.name,
                html=str(html) if html.exists() else None,
                md=str(md) if md.exists() else (str(tf) if tf.exists() else None))
            # An episode declares metadata the same way every other producer does:
            # frontmatter in its doc, meta tags in its rendered page. Without this
            # an episode could never carry tags no matter what was written in it.
            declared = [parse_frontmatter(f) for f in (md, tf) if f.exists()]
            if html.exists():
                declared.append(parse_html_meta(html.read_text(errors="replace")[:20000]))
            items.append(apply_declared(item, *declared))
    if items:
        log.append(f"episodes: {len(items)}")
    return items


# ------------------------------------------------------------- 4. index
# --------------------------------------------------------- 5b. notes records
def scope_css(css, sel="#note"):
    """Re-root a self-contained page's stylesheet so it cannot escape its box.

    HQ pages are written to stand alone: each declares `:root` custom properties
    and styles `body` directly. Dropped into a site verbatim, those two repaint
    the host. Rewriting them to the container keeps every rule the page relies
    on, including its dark-mode block, and confines all of it.
    """
    css = re.sub(r"(?<![\w-]):root\b", sel, css)
    css = re.sub(r"(?m)(^|[,{}\s])body\b", r"\1" + sel, css)
    return css


def note_record(item, log):
    """One catalog entry to one JSON record the site can render.

    The BODY travels, not a link to it. A note whose text lives in an iframe or
    behind a fetch is a note a search engine never reads, and the entire point
    of publishing these is that the work becomes a surface.
    """
    src = Path(item["html"])
    try:
        raw = src.read_text(errors="replace")
    except OSError as e:
        log.append(f"notes: cannot read {src}: {e}")
        return None
    # The same scrub the hosted copy gets: no session id, no home path, no
    # deep link that only resolves on one Mac.
    raw, _ = strip_session_footer(raw, public_url=None)
    raw = re.sub(r"<footer\b(?:(?!</footer>).)*?"
                 r"(?:data-tb-agent=|tranquilitybase://)"
                 r"(?:(?!</footer>).)*?</footer>", "", raw, flags=re.S)
    css = "\n".join(scope_css(m.group(1))
                    for m in re.finditer(r"<style[^>]*>(.*?)</style>", raw, re.S))
    m = re.search(r"<body[^>]*>(.*)</body>", raw, re.S)
    body = m.group(1) if m else raw
    body = re.sub(r"<script\b.*?</script>", "", body, flags=re.S | re.I)
    return {
        "slug": item["slug"], "title": item["title"],
        "summary": item.get("summary", ""), "question": item.get("question", ""),
        "date": item["date"], "updated": item.get("updated") or item["date"],
        "brand": item.get("brand", ""), "type": item.get("type", ""),
        "tags": item.get("tags") or [], "css": css, "body": body,
    }


def emit_notes(hq, catalog, log):
    """Write the hosted subset as records for the site to render.

    Records, not pages. Copying finished HTML to a static host gets correct
    pages with no site around them: no topic index, no cross-links, no shared
    chrome, no sitemap that knows what it contains. The site renders from these
    and gets all four, and the report body is still the HTML already written.
    """
    out = roots.notes
    # Superseded work does not go on the public surface. It stays in the index
    # and on its agent's hub, where the history is the point; a search engine
    # offered four versions of one report indexes none of them well, and a
    # reader who lands on the old one has been sent somewhere wrong.
    # `visibility: hosted` has always meant one thing: the private HQ site, at a
    # URL nobody links, with robots set to disallow. Pointing the same flag at an
    # INDEXED personal domain quietly changes what it authorises, and it was set
    # on client work under the old meaning. So a brand can be held back from the
    # public surface without touching the flag on 89 existing reports.
    #
    # Client-identifiable work is excluded by default and opted in per brand,
    # rather than the reverse. Getting this wrong in the safe direction costs a
    # config line; getting it wrong in the other direction is a client reading
    # their own audit on a stranger's blog.
    # The denylist that already guards every other public surface.
    #
    # A brand FIELD is not a content gate, and trusting it was a real mistake:
    # thirteen reports filed under the vendor named the client in their own
    # titles, so "hold Mirai" published "Mirai Clinical Send Plan" anyway. The
    # content engine has carried a deterministic denylist since July for exactly
    # this ("nothing privileged may reach a public surface"), applied at the
    # publisher intake and the harvest gate. The notes surface is a third public
    # surface and had none of it.
    #
    # Blocked, not scrubbed, matching that module's own ruling: scrubbing
    # privileged information is too error-prone to trust for auto-publish.
    try:
        sys.path.insert(0, str(Path.home() / "Projects/content-engine"))
        import privacy
        deny = privacy.scan
    except Exception as e:
        log.append(f"notes: REFUSING to publish, privacy denylist unavailable ({e})")
        return
    # PUBLISHING IS A MANUAL ACT, one page at a time.
    #
    # `visibility: hosted` was never a decision to publish; it meant a private
    # Vercel URL with robots disallowed. Treating it as consent put 27 pages on
    # an indexed domain that nobody had chosen to put there. So the surface is
    # an explicit allowlist of slugs, empty by default, and the denylist and the
    # brand hold below remain as gates on top of it. Nothing reaches the web
    # because it merely qualified.
    allow = list((hq.cfg.get("notes", {}) or {}).get("publish", []))
    if not allow:
        for old in out.glob("*.json"):
            old.unlink()
        log.append("notes: none published (notes.publish is empty; publishing is opt-in per slug)")
        return
    hold = {b.lower() for b in (hq.cfg.get("notes", {}) or {}).get("hold_brands", [])}
    hosted, held = [], 0
    for i in catalog:
        if i.get("slug") not in allow:
            continue
        if i.get("visibility") != "hosted" or not i.get("html"):
            continue
        if i.get("status") == "superseded":
            continue
        if (i.get("brand") or "").lower() in hold:
            held += 1
            continue
        hosted.append(i)
    if held:
        log.append(f"notes: {held} record(s) held back by notes.hold_brands")
    if not hosted:
        return
    if not out.parent.exists():
        log.append(f"notes: {out.parent} does not exist, skipping")
        return
    out.mkdir(parents=True, exist_ok=True)
    # Rebuilt from scratch: an unpublished note must LEAVE the site, and a
    # stale file nobody deletes is how a retracted page stays up.
    for old in out.glob("*.json"):
        old.unlink()
    # A page that will not load is not published, whatever the flag says.
    #
    # Two audit pages embed their evidence as base64 screenshots and run to 20MB
    # and 16MB, against a 409KB median. Vercel refuses to prerender them (the
    # served response roughly doubles the record, so the real ceiling is about
    # half the platform limit), and no reader on a phone would wait for one
    # either. They stay in the index and on their agent's hub, where the
    # evidence is the point; they do not become web pages until their images
    # are files rather than data URIs.
    LIMIT = 8_000_000
    written = skipped = blocked = 0
    for it in hosted:
        rec = note_record(it, log)
        if rec:
            # Scan the SOURCE FILE, not the extracted body.
            #
            # The extraction drops <head>, scripts and styles, and a client name
            # in a <title>, a meta tag or an inline data attribute is just as
            # published as one in a paragraph. Reviewing the whole file against
            # the same denylist found seven pages the body-only scan had passed.
            try:
                whole = Path(it["html"]).read_text(errors="replace")
            except OSError:
                whole = ""
            hits = deny(" ".join([rec["title"], rec["summary"], rec["question"],
                                  rec["body"], whole]))
            if hits:
                log.append(f"notes: BLOCKED {rec['slug']} ({', '.join(sorted(set(hits))[:3])})")
                blocked += 1
                rec = None
        if rec and len(rec["css"]) + len(rec["body"]) > LIMIT:
            mb = (len(rec["css"]) + len(rec["body"])) / 1e6
            log.append(f"notes: SKIPPED {rec['slug']} ({mb:.1f}MB, embedded assets)")
            skipped += 1
            rec = None
        if rec:
            (out / (rec["slug"] + ".json")).write_text(
                json.dumps(rec, indent=1, ensure_ascii=False))
            written += 1
    log.append(f"notes: {written} record(s) -> {out}"
               + (f", {blocked} blocked by the privacy denylist" if blocked else "")
               + (f", {skipped} skipped as oversized" if skipped else ""))


def hub_name(path):
    """The name a hub already calls itself.

    Not a parallel lookup. Every hub renders its own name, from a title the app
    resolved when it wrote the page, so the page IS the source: reading it back
    cannot disagree with what a reader sees when they open it. Building a second
    name table out of callsigns and transcripts would cover fewer agents and
    could drift from this one. 452 of 452 hubs answer.
    """
    try:
        head = path.read_text(errors="replace")[:60000]
    except OSError:
        return ""
    m = re.search(r"Created by <b>(.*?)</b>", head, re.S) \
        or re.search(r"<title>(.*?)</title>", head, re.S)
    if not m:
        return ""
    name = htmllib.unescape(re.sub(r"<[^>]+>", "", m.group(1))).strip()
    name = re.sub(r"\s*[\u2014-]\s*agent$", "", name)          # the <title> suffix
    # A name has to be readable to be a name. A hub whose title was only the
    # suffix leaves a bare dash, and an id repeated back is not a name either;
    # both fall through to "Agent <id>", which at least says what it is.
    if not re.search(r"[A-Za-z0-9]", name):
        return ""
    return "" if re.fullmatch(r"(Agent )?[0-9a-fA-F-]{6,}", name) else name


MOVED_META = re.compile(
    rb'<meta\s+name="intranet:moved"\s+content="([^"]+)"', re.I)


def _declared_moved(index):
    """When the hub says its agent last moved; its mtime only as a fallback.

    Only the head is read — the tag is in the first few hundred bytes by
    construction, and a hub is a large file rewritten every turn.

    A hub written before this tag existed has no declaration, and for those the
    mtime is still the best guess available. It ages out on its own: the next
    turn that agent takes rewrites its hub with the tag.
    """
    try:
        with open(index, "rb") as fh:
            head = fh.read(2048)
    except OSError:
        return datetime.fromtimestamp(0)
    m = MOVED_META.search(head)
    if m:
        try:
            return datetime.fromisoformat(
                m.group(1).decode("utf-8", "replace").replace("Z", "+00:00")
            ).astimezone().replace(tzinfo=None)
        except ValueError:
            pass
    try:
        return datetime.fromtimestamp(index.stat().st_mtime)
    except OSError:
        return datetime.fromtimestamp(0)


def render_top(hq, catalog, log, built_note):
    """The index over the agents: a list of names, and the hub itself.

    290 hubs and no way in. Each one is a good page and finding one meant
    already knowing an eight-character id, which is the opposite of what an
    index is for.

    Two things this deliberately does NOT do, both of them mistakes the first
    version made. It does not paraphrase a hub into a second listing of the same
    links: the hub already answers "what has this agent done", so the pane
    frames it instead. And it carries no identity colour, because in this system
    colour is state: StateLegend rules green as "go", blue as "working" and
    amber as "stopped, needs you", with measured contrast and a dark-panel
    doctrine behind them. A column of coloured dots meaning nothing sits in
    front of a reader trained to read those exact hues as status.
    """
    root = roots.agents
    counts = {}
    for it in catalog:
        sid = (it.get("session") or "").strip()
        if sid:
            counts[sid] = counts.get(sid, 0) + 1

    terms = {}
    dates = {}
    for it in catalog:
        sid = (it.get("session") or "").strip()
        if not sid:
            continue
        terms.setdefault(sid, []).append(
            " ".join([it.get("title", ""), it.get("summary", "")]
                     + (it.get("tags") or [])))
        d = it.get("date") or ""
        if d > dates.get(sid, ""):
            dates[sid] = d

    agents = []
    if root.is_dir():
        for d in sorted(root.iterdir()):
            index = d / "index.html"
            # Not the compatibility symlinks: since 06 Sep a directory is the
            # full session id and the eight-character name links to it, so
            # following the links listed every agent twice (1000 for 510).
            if not (d.is_dir() and not d.is_symlink()
                    and not d.name.startswith("_") and index.exists()):
                continue
            # WHEN THE AGENT LAST MOVED, not when it last wrote something.
            #
            # This sorted by the newest PAGE date, so an agent that had been
            # working all day and had not written a report had no date at all
            # and sank to the bottom of 465 rows — invisible, while the grid
            # showed it near the top. Reported 02 Sep: "the order is not the
            # same in the hub of hubs as in the grid, and thus many turns seem
            # missing". They were not missing; they were last.
            #
            # The hub DECLARES when its agent last moved. Read that.
            #
            # This used to stat() the hub file, reasoning that the app rewrites
            # it at every turn end so mtime and last-activity agree. They agree
            # only until something else writes the file, and something else
            # keeps writing the file: the 02 Sep migration stamped 395 hubs
            # with its own date and the 04 Sep link surgery stamped 82 more.
            # A third of this index claimed activity on a day those agents did
            # nothing, so the ordering meant nothing — reported twice, once as
            # "the order is not the same as the grid" and once as "it shows
            # 2026-09-04 but the last move is August 17".
            #
            # An mtime answers "when was this file written". Only the agent's
            # own last turn answers "when did this agent last work".
            moved = _declared_moved(index)
            agents.append({
                "id": d.name,
                "name": hub_name(index),
                "pages": counts.get(d.name, 0),
                "last": moved.strftime("%Y-%m-%d"),
                "moved": moved.timestamp(),
                "terms": " ".join(terms.get(d.name, []))[:4000],
            })
    agents.sort(key=lambda a: a["moved"], reverse=True)

    tpl = SKILL_DIR / "templates" / "top.html"
    if not tpl.exists():
        log.append(f"top: template missing at {tpl}")
        return
    named = sum(1 for a in agents if a["name"])
    note = (f"{len(agents)} agents \u00b7 {named} named \u00b7 built {built_note}")
    html = (tpl.read_text()
            .replace("/*__AGENTS__*/[]", json.dumps(agents).replace("</", "<\\/"))
            .replace("__AGENTS_ROOT__", str(root))
            .replace("__BUILT__", note))
    root.mkdir(parents=True, exist_ok=True)
    (root / "index.html").write_text(MARK + MARKER + "\n" + html)
    log.append(f"top: {len(agents)} agent(s), {named} named -> {root / 'index.html'}")


def render_index(hq, items, out_path, built_note):
    if not hq.template.exists():
        sys.exit(f"research-hq: template not found: {hq.template}")
    data = json.dumps(items).replace("</", "<\\/")
    html = (hq.template.read_text()
            .replace("/*__DATA__*/[]", data)
            .replace("__BUILT__", built_note)
            .replace("__AGENTS_ROOT__", str(roots.agents))
            .replace("__TITLE__", htmllib.escape(hq.title)))
    out_path.write_text(MARK + html)


# ------------------------------------------------------------- 5. publish
# ---------------------------------------------------------------- tbase footer

TBASE_INSTALL = "https://github.com/robertnowell/tranquility-base"
TBASE_SCHEME = re.compile(r"(tranquilitybase|voicedispatch)://[^\"'\s>]*")
TBASE_FOOTER = re.compile(
    r"<footer\b[^>]*>.*?</footer>", re.IGNORECASE | re.DOTALL)


def strip_session_footer(html, public_url=None):
    """Make a locally-stamped page safe to host, WITHOUT making it inert.

    A session artifact carries a footer naming the agent that wrote it: the
    Claude Code title, the Tranquility Base callsign, the session id, and a deep
    link whose `ref` is the file's ABSOLUTE path. Every one of those has to go
    the moment the page has a public URL. The title is model-written from the
    author's own conversation and can say anything at all; the path exposes
    ~/Projects/<client-name>; the id is an internal handle; and the button
    cannot work for anyone but the author, because it names a session and a file
    that exist on exactly one Mac.

    But the identifiers live INSIDE the link, so removing them removed the
    button too — and the button is the entire reason a shared page is worth
    stamping. So the link stays and is rewritten to carry nothing but the page's
    own public address: a reader with the app is offered a fresh session that
    opens holding this page, and a reader without one is pointed at the repo.
    That is the whole public loop, and it needs no identifier to work.

    Returns (html, changed).
    """
    if "tranquilitybase://" not in html and "voicedispatch://" not in html:
        return html, False

    # ONE button, with one label, everywhere. The local page and the hosted copy
    # say "Discuss with agent" and point at tranquilitybase://discuss?ref=… —
    # the only difference is what the ref names and what the line above it can
    # safely say. A different label on the public copy would mean the thing a
    # stranger learns to look for is not the thing the author sees.
    #
    # The attribution names the TOOL, never the harness. Which coding agent
    # wrote the page is a fact with a short shelf life; that it was dispatched
    # from Tranquility Base is the part that stays true, and it is also the only
    # part a reader can act on.
    made = ('Made with <a href="' + TBASE_INSTALL + '" style="color:inherit">'
            'Tranquility Base</a>')
    # No hosted URL resolved (no base configured): the button still opens the
    # app, it simply has no page to name.
    ref = f"?ref={htmllib.escape(public_url)}" if public_url else ""
    door = (f'<a href="tranquilitybase://discuss{ref}" '
            'style="color:inherit;font-weight:600">Discuss with agent</a>')
    made = f"{made} &middot; {door}"
    fallback = f"tranquilitybase://discuss{ref}"

    def replace(match):
        block = match.group(0)
        if "tranquilitybase://" not in block and "voicedispatch://" not in block:
            return block
        return block[:block.index(">") + 1] + made + "</footer>"

    out = TBASE_FOOTER.sub(replace, html)
    # Belt: a deep link the model put somewhere other than a <footer> loses its
    # session and its path the same way. A dead button is a bug; a button
    # carrying someone's home directory into a public URL is a disclosure.
    out = TBASE_SCHEME.sub(fallback, out)
    return out, True


def copy_hosted_html(src, dst, slug, log, public_url=None):
    """Copy one hosted page, rewriting anything that only made sense locally."""
    html = Path(src).read_text(encoding="utf-8", errors="replace")
    html, changed = strip_session_footer(html, public_url)
    Path(dst).write_text(html, encoding="utf-8")
    if changed:
        log.append(f"  {slug}: session footer replaced with the public one")
    # The gate. The scheme must never survive, and a home path in a hosted page
    # is worth saying out loud even when it is legitimately part of the content.
    leaked = Path(dst).read_text(encoding="utf-8", errors="replace")
    # The public link is deliberate; what must never survive is one carrying an
    # identifier. Those are exactly the ones with a session or a local ref.
    if re.search(r"tranquilitybase://[^\"'\s>]*(session=|ref=/)", leaked) \
            or "voicedispatch://" in leaked:
        log.append(f"  !! {slug}: a deep link kept an identifier — NOT SAFE TO HOST")
    if str(Path.home()) in leaked:
        log.append(f"  ?? {slug}: contains {Path.home()} — check before sharing")


def sync_hosted(hq, catalog, log, deploy=False):
    """Build the hosted subset as a static site; optionally push it.

    Hosting is opt-in per item (visibility: hosted) and the hosted index lists
    only hosted items, so a private title never reaches the public surface."""
    base = hq.base_url()
    # THE HOSTED SITE IS PUBLIC. Ruled 7 Sep: hub documents are private, and
    # public only once deliberately published.
    #
    # `visibility: hosted` has always MEANT "the private HQ site" -- emit_notes
    # says so in its own comment two functions below. It has never BEEN private.
    # Measured 7 Sep: an anonymous GET of hq-rendition.vercel.app returned 200,
    # and 20 of 112 hosted items carried a hold_brands brand -- Mirai Clinical
    # segmentation triage, brand bibles for Mirai and U Vape, a Labor Day
    # ladder. The only thing between those and a crawler was robots.txt, which
    # is a request, not a control, and which T1.1 proposed to switch off.
    #
    # Vercel Authentication would make this surface genuinely private, but it
    # is a Pro-plan feature and this account is Hobby: the API refuses with
    # "Vercel Authentication is not available on your plan for production
    # deployments". So on this platform "hosted" cannot mean "private", and
    # until the app serves this over Tailscale, the honest move is to keep
    # client work off the public surface entirely.
    #
    # The brand hold that already guards the notes surface now guards this one.
    # It is a floor, not a ceiling: it holds five named brands and knows
    # nothing about anything else, so it is not a substitute for the surface
    # being private.
    hold = {b.lower() for b in ((hq.cfg.get("notes", {}) or {}).get("hold_brands") or [])}
    hosted, held_back = [], 0
    for i in catalog:
        if i.get("visibility") != "hosted" or not i.get("html"):
            continue
        if (i.get("brand") or "").lower() in hold:
            held_back += 1
            continue
        hosted.append(i)
    if held_back:
        log.append(f"site: {held_back} item(s) held back (client brand, hq.json notes.hold_brands)")
    # The site is rebuilt from scratch each run, but host link state (.vercel/,
    # .netlify/, CNAME…) must survive — losing it makes every deploy create a NEW
    # project instead of updating the existing one.
    keep = {}
    if hq.site.exists():
        for p in hq.site.iterdir():
            if p.name.startswith(".") or p.name == "CNAME":
                keep[p.name] = hq.site.parent / f".keep-{p.name}"
                shutil.move(str(p), str(keep[p.name]))
        shutil.rmtree(hq.site)
    hq.site.mkdir(parents=True)
    for name, stashed in keep.items():
        shutil.move(str(stashed), str(hq.site / name))
    pub = []
    for it in hosted:
        (hq.site / it["slug"]).mkdir(exist_ok=True)
        copy_hosted_html(it["html"], hq.site / it["slug"] / "index.html",
                         it["slug"], log,
                         f"{base}/{it['slug']}/" if base else None)
        if it.get("md"):
            shutil.copy(it["md"], hq.site / it["slug"] / "report.md")
        # Sibling assets the page references relatively (images, CSVs, media
        # dirs) must ship too — an index.html-only copy 404s every asset link.
        ASSET_EXT = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".css",
                     ".js", ".csv", ".json", ".pdf", ".mp4", ".webm", ".woff2"}
        src_dir = Path(it["html"]).parent
        copied = 0
        for entry in src_dir.iterdir():
            if entry.name.startswith(".") or entry.name in (
                    "index.html", "report.html", "report.md", "meta.json"):
                continue
            dst = hq.site / it["slug"] / entry.name
            if entry.is_dir():
                shutil.copytree(entry, dst, dirs_exist_ok=True)
                copied += sum(1 for _ in entry.rglob("*") if _.is_file())
            elif entry.suffix.lower() in ASSET_EXT:
                shutil.copy(entry, dst)
                copied += 1
        if copied:
            log.append(f"  {it['slug']}: +{copied} asset file(s)")
        url = f"{base}/{it['slug']}/" if base else None
        pub.append(dict(it, href=it["slug"] + "/", md=None, url=url))
        if url:                      # deterministic URL flows back to the local catalog
            it["url"] = it["url"] or url
    render_index(hq, pub, hq.site / "index.html",
                 datetime.now().strftime("%Y-%m-%d") + " · hosted")
    # Indexing an unprotected surface is the one-way door. Ruled 7 Sep: this
    # site is private by intent, so it is never indexable, and a config typo
    # must not be able to change that quietly.
    if (hq.host or {}).get("robots", "disallow") == "allow":
        log.append("site: robots=allow IGNORED -- the HQ site is private by "
                   "design and is never indexed. Publish to the notes surface "
                   "instead (hq.json notes.publish).")
    if True:
        # link-shareable, not search-discoverable
        (hq.site / "robots.txt").write_text("User-agent: *\nDisallow: /\n")
    log.append(f"site: {len(hosted)} hosted item(s) -> {hq.site}")
    if not deploy:
        return
    if not hosted:
        log.append("nothing to deploy (no items declare visibility: hosted)")
        return
    deploy_site(hq, log)


def deploy_site(hq, log):
    provider = (hq.host or {}).get("provider", "vercel")
    if provider == "none":
        log.append("host.provider is 'none' — site built, not deployed")
        return
    if provider == "command":
        cmd = (hq.host or {}).get("deploy_cmd")
        if not cmd:
            log.append("host.provider is 'command' but host.deploy_cmd is unset")
            return
        r = subprocess.run(cmd, shell=True, cwd=hq.site, capture_output=True, text=True)
        out = (r.stdout + r.stderr).strip()
        log.append(("deployed: " if r.returncode == 0 else "deploy FAILED: ") + out[-300:])
    elif provider == "vercel":
        # Vercel requires CLI >= 47.2 (Aug 2026) and that CLI needs Node >= 18. The machine's
        # default node is 16 and the global `vercel` is 39.x, so prefer the newest nvm Node
        # and run the latest CLI through npx. host.vercel_cmd in config overrides the command.
        env = dict(os.environ)
        nvm_nodes = sorted((Path.home() / ".nvm" / "versions" / "node").glob("v2*"),
                           key=lambda d: [int(x) for x in d.name[1:].split(".")])
        if nvm_nodes:
            env["PATH"] = str(nvm_nodes[-1] / "bin") + os.pathsep + env.get("PATH", "")
        vcmd = (hq.host or {}).get("vercel_cmd") or "npx -y vercel@latest"
        if not (have("npx") or have("vercel")):
            log.append("neither npx nor vercel found: install Node >= 18 (nvm) or npm i -g vercel@latest, "
                       "or set host.provider to 'command' with your own deploy_cmd")
            return
        scope = (hq.host or {}).get("scope")
        cmd = f"{vcmd} deploy --prod --yes" + (f" --scope={scope}" if scope else "")
        r = subprocess.run(cmd, shell=True, cwd=hq.site, capture_output=True, text=True, env=env)
        m = re.search(r"https://[a-z0-9.-]+\.vercel\.app", r.stdout + r.stderr)
        if r.returncode == 0 and m:
            if not hq.url_file.exists() and not (hq.host or {}).get("base_url"):
                # first deploy: remember it, but prefer a stable alias in config
                hq.url_file.write_text(m.group(0))
            log.append(f"deployed: {m.group(0)}  (base: {hq.base_url() or m.group(0)})")
            log.append("note: if the URL asks for a login, deployment protection is on — "
                       "run share-as-page/scripts/vercel-unprotect.sh on this site dir")
        elif r.returncode == 0 and hq.base_url():
            # A custom domain prints no *.vercel.app, so matching only that
            # regex made a SUCCESSFUL deploy log "FAILED". The configured
            # base_url is what every catalog URL is built from anyway.
            log.append(f"deployed: {hq.base_url()}  (no vercel.app URL in output)")
        else:
            log.append(f"deploy FAILED: {(r.stderr or r.stdout).strip()[:300]}")
    else:
        log.append(f"unknown host.provider: {provider}")


def write_starter_config(path):
    path = Path(path).expanduser()
    if path.exists():
        sys.exit(f"research-hq: {path} already exists — edit it, or pass --config elsewhere")
    path.parent.mkdir(parents=True, exist_ok=True)
    starter = json.loads(json.dumps(DEFAULTS))
    starter["scan"]["page_roots"] = ["~/Projects"]
    starter["brand_rules"] = [["acme", "Acme"], ["personal", "Personal"]]
    path.write_text(json.dumps(starter, indent=2) + "\n")
    print(f"wrote {path}\n\nEdit it — the fields that matter most:\n"
          "  hq_root      where your research reports live\n"
          "  out_dir      where the generated index goes\n"
          "  brand_rules  keyword → label, first match wins (drives grouping)\n"
          "  host         vercel | command (any static host) | none\n"
          "  scan         extra dirs/globs holding pages you also want indexed")


def main():
    ap = argparse.ArgumentParser(prog="publish.py", add_help=True,
                                 description="Index and publish your research HQ.")
    ap.add_argument("--deploy", action="store_true", help="also deploy the hosted subset")
    ap.add_argument("--config", help="config file (default: $HQ_CONFIG or ~/.claude/hq.json)")
    ap.add_argument("--init", metavar="PATH", nargs="?", const="~/.claude/hq.json",
                    help="write a starter config and exit")
    args = ap.parse_args()

    if args.init:
        return write_starter_config(args.init)

    cfg, cfg_path = load_config(args.config)
    hq = HQ(cfg)
    if not hq.root.is_dir():
        sys.exit(f"research-hq: hq_root does not exist: {hq.root}\n"
                 f"Create it, or set hq_root in your config ({cfg_path or 'none loaded'}).")
    hq.out.mkdir(parents=True, exist_ok=True)

    log = [f"config: {cfg_path or 'defaults (no config file)'}"]
    normalize(hq, log)
    render_reports(hq, log)
    items = (collect_reports(hq) + collect_agent_pages(hq) + collect_pages(hq)
             + collect_extra_html(hq) + collect_episodes(hq, log))
    catalog = sorted(items, key=lambda x: x["date"], reverse=True)
    sync_hosted(hq, catalog, log, deploy=args.deploy)     # resolves hosted URLs
    emit_notes(hq, catalog, log)                          # records for the site
    (hq.out / "catalog.json").write_text(json.dumps(catalog, indent=1))
    # The vocabulary, for the thing that has to choose from it.
    #
    # hq-tags derives this on demand for a human at a terminal. The artifact
    # hook needs the same list at the moment a page is written, inside a hook
    # that must never be slow and must never fail, so it is written out here as
    # a flat [[term, count]] file rather than re-derived from a 1.2 MB catalog
    # on every Write. Same source, same freshness: it cannot drift from the
    # corpus because it IS the corpus, counted.
    (hq.out / "tags.json").write_text(json.dumps(
        Counter(t for it in catalog for t in (it.get("tags") or [])).most_common(),
        indent=0))
    built = datetime.now().strftime("%Y-%m-%d %H:%M")
    render_index(hq, catalog, hq.out / "index.html", built)
    # The count comes from render_top, which knows how many rows it drew.
    # Counting sessions in the catalog here said 129 while the sidebar listed
    # 460, because an agent with a directory and nothing indexed is still an
    # agent. A label that disagrees with the list under it is worse than none.
    render_top(hq, catalog, log, built)
    log.append(f"catalog: {len(catalog)} items -> {hq.out / 'index.html'}")
    print("\n".join(log))


if __name__ == "__main__":
    sys.exit(main())
