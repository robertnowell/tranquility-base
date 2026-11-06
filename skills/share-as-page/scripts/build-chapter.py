"""build-chapter.py <slug> <chapter-number> <title>
Reads <slug>-body.html, <slug>-refs.py (REFS, A) and optional <slug>-figures.py (FIGS dict name->fn) in this folder,
scaffolds a draft on the chapter template, splices body, figures and sources, carries archive links from a previous
audit JSON, and writes _drafts/<slug>.html."""
import re, html, json, os, sys, subprocess
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(HERE, "..", "figures"))
from importlib.machinery import SourceFileLoader
slug, num, title = sys.argv[1], sys.argv[2], sys.argv[3]
SESSION = "360cebe8-e728-4fb4-857e-7d0f6e45c42a"
A = f"/Users/robertnowell/Documents/agents/{SESSION}/"
DRAFT = A + f"_drafts/{slug}.html"
refs = SourceFileLoader("refs", os.path.join(HERE, f"{slug}-refs.py")).load_module()
body = open(os.path.join(HERE, f"{slug}-body.html"), encoding="utf-8").read()
# scaffold under a temporary slug (the live page may exist), then rename
tmp = f"{slug}-build"
for p in (DRAFT, A + f"_drafts/{tmp}.html"):
    if os.path.exists(p): os.remove(p)
r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "..", "chapter-type", "chapter-new.py"), tmp, f"--session={SESSION}",
                    "--series=The agent platform", f"--chapter={num}", "--brand=Coframe"], capture_output=True, text=True)
if r.returncode: sys.exit(r.stderr)
os.replace(A + f"_drafts/{tmp}.html", DRAFT)
# figures
figp = os.path.join(HERE, f"{slug}-figures.py")
if os.path.exists(figp):
    figs = SourceFileLoader("figs", figp).load_module()
    for key, fn in figs.FIGS.items():
        body = body.replace("{{" + key.upper() + "}}", fn())
# sources, carrying archives from the last audit
prev = {}
aj = DRAFT.replace(".html", ".audit.json")
if os.path.exists(aj):
    prev = {k: (v.get("archive_new") or v.get("archive") or "") for k, v in json.load(open(aj))["sources"].items()}
lis = []
for rid, who, t, when, url, loc, quote in refs.REFS:
    live = f'<a href="{html.escape(url)}">live</a>' if url.startswith("http") else f'<a href="file://{html.escape(url)}">local file</a>'
    arch = prev.get(rid, "") if prev.get(rid, "").startswith("http") else ""
    archlink = f' · <a href="{html.escape(arch)}">archive</a>' if arch else ""
    lis.append(f'<li id="{rid}" data-url="{html.escape(url)}" data-archive="{html.escape(arch)}" data-accessed="{refs.A}" data-locator="{html.escape(loc)}">'
               f'<span class="who">{html.escape(who)}</span>, {html.escape(t)}, {html.escape(when)}.'
               f'<span class="meta">{live}{archlink} · accessed {refs.A} · {html.escape(loc)}</span>'
               f'<q>{html.escape(quote)}</q></li>')
body = body.replace("{{SOURCES}}", "\n".join(lis))
left = re.findall(r"\{\{[A-Z_]+\}\}", body)
if left: sys.exit(f"unfilled figure placeholders: {left}")
draft = open(DRAFT, encoding="utf-8").read()
head, rest = draft.split('<div class="k">', 1)
kicker_line = rest.split("</div>", 1)[0]
text_words = len(re.findall(r"\S+", re.sub(r"<[^>]+>", " ", body.split('<section class="sources">')[0])))
page = head + f'<div class="k">{kicker_line} · {text_words:,} words</div>\n' + body + "\n</main></body></html>\n"
page = page.replace("<title><!-- TITLE: the thesis, under ten words --></title>", f"<title>{html.escape(title)}</title>")
meta = getattr(refs, "META", {})
page = page.replace('content="FILL: one sentence"', f'content="{html.escape(meta.get("description", title))}"')
page = page.replace('content="FILL: the thesis in one sentence"', f'content="{html.escape(meta.get("summary", title))}"')
page = page.replace('content="FILL: 2 to 4 tags from hq-tags"', f'content="{html.escape(meta.get("tags", "crobot, chapter"))}"')
open(DRAFT, "w", encoding="utf-8").write(page)
print(f"built {DRAFT}: {text_words} words, {len(refs.REFS)} sources")
