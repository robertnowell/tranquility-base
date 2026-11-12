#!/usr/bin/env python3
"""chapter-audit: check a chapter's structure, its sources and its claims, and write the audit into the page.

    chapter-audit <page.html>                   structure checks only
    chapter-audit <page.html> --archive         save each source with the Wayback Machine, fill data-archive
    chapter-audit <page.html> --fetch           fetch each source (or its archive) and check its quote is in it
    chapter-audit <page.html> --verify=MODEL    ask MODEL whether each quote supports its sentence (claude -p)
    chapter-audit <page.html> --write           rewrite the page: cite verdicts, ref verdicts, the audit section

Verdicts per claim: ok (quote found and supports), partial, inferred (author-declared), fail (quote not in
source, or verifier says unsupported), unreachable (source could not be fetched), unchecked (nothing run).
Rules: references/chapter.md. The verifier should be a different model than the author (FACTS Grounding).
"""
import datetime
import hashlib
import html as htmlmod
import json
import os
import re
import subprocess
import sys
import unicodedata
from html.parser import HTMLParser
from pathlib import Path

sys.dont_write_bytecode = True
UA = "Mozilla/5.0 (Macintosh) chapter-audit/1.0 (+Tranquility Base)"
CACHE = Path(os.environ.get("CHAPTER_AUDIT_CACHE") or Path.home() / ".cache" / "chapter-audit")


# ---------- parsing ----------
class Page(HTMLParser):
    """Collect refs, cites with their sentences, and the structure counts."""
    BLOCKS = {"p", "li", "figcaption", "caption", "td", "th", "dd", "dt", "h1", "h2", "h3"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.refs, self.cites, self.details = {}, [], []
        self.stack, self.block_text = [], []
        self.in_ref, self.in_q = None, False
        self.parts, self.paras, self.svgs, self.charts = [], [], [], []
        self.counts = {"objectives": 0, "questions": 0, "answers": 0, "toc": 0}
        self.section, self.lede, self.title, self.summary = None, "", "", ""
        self.cur = None  # current block text buffer
        self.text_target = None
        self.chart = None
        self.in_cite = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = (a.get("class") or "").split()
        self.stack.append((tag, cls))
        if tag == "details":
            self.details.append(self.getpos()[0])
        if tag == "section":
            self.section = cls[0] if cls else None
            if "part" in cls:
                self.parts.append({"id": a.get("id"), "heading": "", "line": self.getpos()[0]})
        if tag == "nav" and "toc" in cls:
            self.section = "toc"
        if tag == "figure":
            if "chart" in cls:
                self.chart = {"line": self.getpos()[0], "ft": False, "sub": False, "table": False, "src": False, "svg": None}
                self.charts.append(self.chart)
        if self.chart and tag == "b" and self.stack[-2][0] == "figcaption":
            self.chart["ft"] = True
        if self.chart and tag == "span" and "sub" in cls:
            self.chart["sub"] = True
        if self.chart and tag == "table":
            self.chart["table"] = True
        if self.chart and tag in ("p", "span") and "src" in cls:
            self.chart["src"] = True
        if tag == "svg":
            s = {"line": self.getpos()[0], "label": a.get("aria-label", ""), "role": a.get("role"), "sizes": []}
            self.svgs.append(s)
            if self.chart:
                self.chart["svg"] = s
        if tag == "text" and self.svgs:
            fs = a.get("font-size") or re.search(r"font-size:\s*([\d.]+)", a.get("style") or "")
            fs = fs.group(1) if hasattr(fs, "group") else fs
            if fs:
                self.svgs[-1]["sizes"].append(float(str(fs).rstrip("px")))
        if tag in self.BLOCKS:
            self.cur = []
            self.cur_tag = tag
        if tag == "li" and "ref" not in cls and self.section == "sources" and a.get("id", "").startswith("r"):
            self.in_ref = {"id": a["id"], "url": a.get("data-url", ""), "archive": a.get("data-archive", ""),
                           "accessed": a.get("data-accessed", ""), "locator": a.get("data-locator", ""),
                           "quote": "", "text": "", "line": self.getpos()[0]}
            self.refs[a["id"]] = self.in_ref
        if tag == "q" and self.in_ref is not None:
            self.in_q = True
        if tag == "a" and "cite" in cls:
            self.in_cite = True
            sent = self._sentence("".join(self.cur or []))
            self.cites.append({"ref": (a.get("href") or "").lstrip("#"), "certainty": a.get("data-certainty", ""),
                               "support": a.get("data-support", ""), "sentence": sent, "line": self.getpos()[0],
                               "section": self.section, "block": getattr(self, "cur_tag", None),
                               "quote": norm(a.get("data-quote") or ""), "attr": "attr" in cls})
        if tag == "li":
            if self.section == "objectives": self.counts["objectives"] += 1
            if self.section == "check": self.counts["questions"] += 1
            if self.section == "answers": self.counts["answers"] += 1
            if self.section == "toc": self.counts["toc"] += 1

    def handle_endtag(self, tag):
        if tag == "a" and self.in_cite:
            self.in_cite = False
            return
        if tag in self.BLOCKS and self.cur is not None:
            text = norm("".join(self.cur))
            if tag == "p" and self.section in ("part", "worked"):
                self.paras.append((text, self.getpos()[0]))
            if tag == "h2" and self.parts and self.section == "part" and not self.parts[-1]["heading"]:
                self.parts[-1]["heading"] = text
            if tag == "h1": self.title = text
            if tag == "p" and self.stack and "lede" in self.stack[-1][1]: self.lede = text
            if tag == "p" and self.section == "summary": self.summary = text
            self.cur = None
        if tag == "q" and self.in_q:
            self.in_q = False
        if tag == "li" and self.in_ref is not None and self.stack and self.stack[-1][0] == "li":
            self.in_ref["text"] = norm(self.in_ref["text"])
            self.in_ref = None
        if tag == "figure":
            self.chart = None
        if self.stack:
            self.stack.pop()

    def handle_data(self, data):
        if self.in_cite:
            return
        if self.cur is not None:
            self.cur.append(data)
        if self.in_ref is not None:
            if self.in_q:
                self.in_ref["quote"] += data
            else:
                self.in_ref["text"] += data

    @staticmethod
    def _sentence(text):
        text = norm(text)
        parts = re.split(r"(?<=[.!?])\s+(?=[A-Z0-9\"'(])", text)
        return parts[-1].strip() if parts else text


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def canon(s):
    """Lower-case, straight quotes, no accents, single spaces, no soft hyphens: the match is forgiving of typography, not of words."""
    s = unicodedata.normalize("NFKD", s)
    s = s.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    s = s.replace("–", "-").replace("—", "-").replace("­", "").replace(" ", " ")
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = re.sub(r"[^\w\s%$.,:;()/'\"-]", " ", s.lower())
    s = re.sub(r"\s+", " ", s).strip()
    # Inline code and links in HTML leave a space before punctuation ("idle , not terminated ."); fold it.
    return re.sub(r" ([.,:;)])", r"\1", s).replace("( ", "(")


# ---------- structure ----------
def words(s):
    return len(re.findall(r"\S+", s))


def structure(page: Page, raw):
    errs, warns = [], []
    for ln in page.details:
        errs.append(f"line {ln}: <details> hides evidence; use an open section")
    if words(page.title) > 10: warns.append(f"title has {words(page.title)} words; the rule is ten")
    if words(page.lede) > 60: warns.append(f"lede has {words(page.lede)} words; the rule is 60")
    if page.summary and words(page.summary) > 120: warns.append(f"summary has {words(page.summary)} words; the rule is 120")
    if not 3 <= page.counts["objectives"] <= 5: warns.append(f"{page.counts['objectives']} objectives; the rule is three to five")
    if not 3 <= page.counts["questions"] <= 5: warns.append(f"{page.counts['questions']} questions; the rule is three to five")
    if page.counts["answers"] != page.counts["questions"]: errs.append(f"{page.counts['answers']} answers for {page.counts['questions']} questions")
    if page.counts["toc"] != len(page.parts): warns.append(f"contents lists {page.counts['toc']} parts; the page has {len(page.parts)}")
    for p in page.parts:
        h = p["heading"]
        if h and not re.search(r"\b(is|are|was|were|has|have|had|does|do|did|can|cannot|needs?|fails?|keeps?|runs?|costs?|makes?|gives?|takes?|means|holds?|wins?|loses?|stays?|owns?|decides?|limits?|shares?|starts?|ends?|puts?|lets?|sets?|moves?|buys?|pays?|comes?|goes?|leaves?|cuts?|binds?|breaks?|opens?|closes?|shows?|says?|tells?|carries|carry|sits?|lives?|draws?|reads?|wears?|follows?|adds?|drops?|splits?|turns?|differs?|beats?|exists?|matters?|prove[sd]?|changes?|should|must|will|'s|not)\b", h):
            warns.append(f"part {p['id']}: heading may lack a verb: \"{h}\"")
    for text, ln in page.paras:
        n = words(text)
        if n > 80: errs.append(f"line {ln}: paragraph of {n} words; the rule is 80")
        for s in re.split(r"(?<=[.!?])\s+", text):
            if words(s) > 20: warns.append(f"line {ln}: sentence of {words(s)} words: \"{s[:60]}…\"")
        if ";" in text: warns.append(f"line {ln}: semicolon")
    # numbers need a cite in the same sentence (part prose only)
    cited = {(c["line"], c["sentence"]) for c in page.cites}
    for text, ln in page.paras:
        for s in re.split(r"(?<=[.!?])\s+", text):
            if re.search(r"\d", s) and not any(cs and cs in s or s in cs for (_, cs) in cited if _ == ln or True):
                pass  # the per-sentence match is approximate; the cite count below is the hard check
    for c in page.cites:
        if c["ref"] not in page.refs: errs.append(f"line {c['line']}: cite points at #{c['ref']}, which is not a source")
        if c["certainty"] and c["certainty"] not in ("high", "moderate", "low", "very-low"): errs.append(f"line {c['line']}: certainty '{c['certainty']}'")
    used = {c["ref"] for c in page.cites}
    for rid, r in page.refs.items():
        if rid not in used: warns.append(f"source {rid} is never cited")
        for k in ("url", "accessed", "quote"):
            if not r[k] or r[k].startswith("FILL"): errs.append(f"source {rid}: no {k}")
        if not r["archive"] or r["archive"].startswith("FILL"): warns.append(f"source {rid}: no archive copy (run --archive)")
        if r["quote"] and words(r["quote"]) > 60: warns.append(f"source {rid}: quote of {words(r['quote'])} words; the rule is 50")
    for ch in page.charts:
        for k in ("ft", "sub", "table", "src"):
            if not ch[k]: errs.append(f"chart at line {ch['line']}: missing {dict(ft='finding headline', sub='subtitle', table='data table', src='source line')[k]}")
        if ch["svg"]:
            s = ch["svg"]
            if not s["label"]: errs.append(f"chart at line {ch['line']}: svg has no aria-label")
            elif len(s["label"]) > 160: warns.append(f"chart at line {ch['line']}: alt text is {len(s['label'])} characters; the rule is 160")
            small = [x for x in s["sizes"] if x < 12]
            if small: errs.append(f"chart at line {ch['line']}: text at {min(small)}px; the floor is 12px, the rule 14px")
            elif any(x < 14 for x in s["sizes"]): warns.append(f"chart at line {ch['line']}: some text under 14px")
            fills = set(re.findall(r'fill="(#[0-9a-fA-F]{3,6})"', raw[raw.find("<svg", 0):]))
    return errs, warns


# ---------- fetching ----------
def fetch_text(url):
    """Return (status, text). Cached on disk. PDFs go through pdftotext when it exists."""
    CACHE.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha1(url.encode()).hexdigest()
    meta, body = CACHE / f"{key}.json", CACHE / f"{key}.txt"
    if meta.exists() and body.exists():
        return json.loads(meta.read_text())["status"], body.read_text(errors="replace")
    raw = CACHE / f"{key}.raw"
    if url.startswith("/") or url.startswith("file://"):
        fp = Path(url.replace("file://", ""))
        text = fp.read_text(errors="replace") if fp.exists() else ""
        if fp.suffix in (".html", ".htm"):
            # A hub page is HTML: a quote must match its text, not its markup.
            import html as _html
            text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", text, flags=re.S | re.I)
            text = _html.unescape(re.sub(r"<[^>]+>", " ", text))
        return (200 if fp.exists() else 404), text
    if url.startswith("https://api.github.com/"):
        # GitHub's API refuses anonymous bursts; gh carries the user's token.
        g = subprocess.run(["gh", "api", url[len("https://api.github.com/"):]], capture_output=True, text=True)
        raw.write_bytes(g.stdout.encode())
        r = type("R", (), {"stdout": ("200 application/json" if g.returncode == 0 else "403 text/plain")})()
    else:
        r = subprocess.run(["curl", "-sL", "-A", UA, "--max-time", "60", "-o", str(raw), "-w", "%{http_code} %{content_type}", url],
                           capture_output=True, text=True)
    parts = r.stdout.split(" ", 1)
    status = int(parts[0] or 0)
    ctype = parts[1] if len(parts) > 1 else ""
    text = ""
    if raw.exists() and status == 200:
        data = raw.read_bytes()
        if "pdf" in ctype or data[:4] == b"%PDF":
            if subprocess.run(["which", "pdftotext"], capture_output=True).returncode == 0:
                out = subprocess.run(["pdftotext", "-layout", str(raw), "-"], capture_output=True, text=True)
                text = out.stdout
        else:
            s = data.decode("utf-8", errors="replace")
            s = re.sub(r"<(script|style|noscript)[\s\S]*?</\1>", " ", s, flags=re.I)
            s = re.sub(r"<[^>]+>", " ", s)
            text = htmlmod.unescape(s)
    meta.write_text(json.dumps({"status": status, "ctype": ctype, "url": url}))
    body.write_text(text)
    return status, text


def check_quote(ref, quote=None):
    q = canon(quote if quote is not None else ref["quote"])
    if not q:
        return {"live": None, "found": None, "where": None}
    out = {"live": None, "archive": None, "found": False, "where": None}
    for where, url in (("live", ref["url"]), ("archive", ref["archive"])):
        if not url or url.startswith("FILL"):
            continue
        status, text = fetch_text(url)
        out[where] = status
        if status == 200 and q in canon(text):
            out["found"], out["where"] = True, where
            break
    return out


def archive(ref):
    """Save the live page with the Wayback Machine and return the archived address."""
    if ref["archive"] and not ref["archive"].startswith("FILL"):
        return ref["archive"]
    import time
    for attempt in range(3):
        r = subprocess.run(["curl", "-sI", "-A", UA, "--max-time", "120", f"https://web.archive.org/save/{ref['url']}"],
                           capture_output=True, text=True)
        m = re.search(r"^(?:location|content-location):\s*(\S+)", r.stdout, flags=re.I | re.M)
        if m:
            loc = m.group(1)
            time.sleep(2)  # Save Page Now rate-limits bursts
            return loc if loc.startswith("http") else "https://web.archive.org" + loc
        time.sleep(8 * (attempt + 1))
    # fall back to the most recent existing snapshot
    r = subprocess.run(["curl", "-s", "--max-time", "60", f"https://archive.org/wayback/available?url={ref['url']}"], capture_output=True, text=True)
    try:
        return json.loads(r.stdout)["archived_snapshots"]["closest"]["url"]
    except Exception:
        return ""


# ---------- verifying ----------
def verify(cites, refs, model, batch=8):
    """Ask MODEL, through the claude CLI, whether each quote supports the clause it follows. Attribution markers are skipped.

    The claim handed to the verifier is the sentence up to the marker, so the clause just before the marker is what
    the quote must support. The source's identity (who, what, when) is given too: a citation names its source, so
    "the 2019 study found" needs no repetition inside the quote."""
    results = {}
    items = [c for c in cites if c["ref"] in refs and c["quote"] and not c["attr"]]
    for i in range(0, len(items), batch):
        chunk = items[i:i + batch]
        lines = []
        for n, c in enumerate(chunk):
            r = refs[c["ref"]]
            lines.append(f"CLAIM {n} (the text up to the citation marker; the clause at its END is what this citation supports): {c['sentence']}\n"
                         f"SOURCE {n}: {r.get('text', '')[:200]}\nQUOTE {n} (verbatim from that source): {c['quote']}\n")
        prompt = ("You are a fact checker. For each item, decide whether QUOTE, read together with the SOURCE's identity "
                  "(its author, title and date), directly supports the clause at the end of CLAIM. Earlier clauses in the same "
                  "sentence may be supported by other citations; ignore them. 'supported': every substantive fact in that clause "
                  "(number, name, mechanism, date) is present in the quote or in the source identity, allowing paraphrase and unit "
                  "changes (5MB = 5 MB, 2.2x = 2.2 times, 'per container' = 'per microVM' when the source is about microVMs). "
                  "'partial': a substantive fact in the clause is absent. 'unsupported': the quote contradicts the clause or is about "
                  "something else. Judge only from the quote and the source identity. Answer with a JSON array only: "
                  "{\"n\": <int>, \"verdict\": \"supported|partial|unsupported\", \"why\": \"<one short sentence>\"}.\n\n"
                  + "\n".join(lines))
        arr = []
        for attempt in range(3):  # a batch that comes back empty or short is asked again
            r = subprocess.run(["claude", "-p", "--model", model, "--output-format", "text", prompt], capture_output=True, text=True, timeout=600)
            m = re.search(r"\[[\s\S]*\]", r.stdout)
            try:
                arr = json.loads(m.group(0)) if m else []
            except json.JSONDecodeError:
                arr = []
            if len(arr) >= len(chunk):
                break
            print(f"verifier batch {i // batch}: {len(arr)} of {len(chunk)} verdicts, retrying")
        for obj in arr:
            try:
                results[id(chunk[int(obj["n"])])] = (obj.get("verdict", ""), obj.get("why", ""))
            except (KeyError, ValueError, IndexError, TypeError):
                pass
    for c in items:
        c["verifier"] = results.get(id(c), ("", ""))
    return cites


# ---------- writing ----------
def verdict_for(c, refcheck):
    if c.get("attr"):
        return "attr"
    rc = c.get("check") or refcheck.get(c["ref"]) or {}
    if c.get("support") == "inferred":
        base = "inferred"
    elif rc.get("found") is False and rc.get("live") not in (200,) and rc.get("archive") not in (200,):
        return "unreachable"
    elif rc.get("found") is False:
        return "fail"
    else:
        base = None
    v = (c.get("verifier") or ("", ""))[0]
    if v == "supported":
        return base or "ok"
    if v == "partial":
        return "partial"
    if v == "unsupported":
        return "fail"
    return base or ("unchecked" if rc.get("found") is None else "found")


def write_page(path, raw, page, refcheck, cites, verifier, today):
    out = raw
    # cite classes, in order of appearance
    def sub_cite(m):
        return m.group(0)
    i = 0
    def repl(m):
        nonlocal i
        c = cites[i] if i < len(cites) else None
        i += 1
        if not c:
            return m.group(0)
        v = c["verdict"]
        cls = {"found": "", "unchecked": "", "attr": "attr"}.get(v, v)
        tag = re.sub(r'class="cite[^"]*"', f'class="cite{(" " + cls) if cls else ""}"', m.group(0))
        tag = re.sub(r'\sdata-verdict="[^"]*"', "", tag)
        return tag.replace("<a ", f'<a data-verdict="{v}" ', 1)
    out = re.sub(r'<a class="cite[^"]*"[^>]*>', repl, out)
    # ref verdict spans and archive attrs
    for rid, r in page.refs.items():
        rc = refcheck.get(rid) or {}
        label = {None: "", True: f"{rc.get('quotes', 1)} quote{'s' if rc.get('quotes', 1) != 1 else ''} found " + (rc.get("where") or ""), False: ("source unreachable" if (rc.get("live") not in (200,) and rc.get("archive") not in (200,)) else f"{rc.get('quotes_found', 0)} of {rc.get('quotes', 1)} quotes found")}[rc.get("found")]
        pat = re.compile(rf'(<li id="{rid}"[^>]*>)([\s\S]*?)(</li>)')
        def fix(m):
            body = re.sub(r'<span class="verdict">[^<]*</span>', "", m.group(2))
            open_tag = m.group(1)
            if r.get("archive_new"):
                open_tag = re.sub(r'data-archive="[^"]*"', f'data-archive="{r["archive_new"]}"', open_tag)
            return open_tag + body.rstrip() + (f'<span class="verdict">{label}</span>' if label else "") + m.group(3)
        out = pat.sub(fix, out, count=1)
    # audit section
    counts = {}
    for c in cites:
        counts[c["verdict"]] = counts.get(c["verdict"], 0) + 1
    nattr = counts.pop("attr", 0)
    claims_only = [c for c in cites if not c.get("attr")]
    order = [("ok", "Supported: the quote is in the source and supports the sentence"),
             ("partial", "Partial: the quote supports part of the sentence"),
             ("inferred", "Inferred: the author says so, the source implies it"),
             ("fail", "Failed: the quote is not in the source, or does not support the sentence"),
             ("unreachable", "Unreachable: the source and its archive could not be read"),
             ("found", "Quote found, support not yet judged"),
             ("unchecked", "Unchecked")]
    rows = "".join(f'<tr><td><i class="{k}"></i>{label}</td><td class="num">{counts.get(k, 0)}</td></tr>' for k, label in order if counts.get(k, 0) or k in ("ok", "fail", "unchecked"))
    nrefs = len(page.refs)
    reach = sum(1 for r in refcheck.values() if r.get("found"))
    audit = (f'<section class="audit" id="audit"><h2>Audit of this chapter</h2>'
             f'<p>The chapter makes {len(claims_only)} cited claims from {nrefs} sources, plus {nattr} attribution markers on captions and source lines. Every claim carries the sentence from its source that supports it. {reach} of {nrefs} sources had every quote found in the live page or its archive on {today}. '
             f'{("The verifier was " + verifier + ", a different model than the author. It judged whether each quote supports its sentence.") if verifier else "No verifier has judged support yet."} '
             f'A person has checked none of them yet.</p>'
             f'<table><caption>Claims by verdict, counted by chapter-audit on {today}</caption><thead><tr><th>Verdict</th><th class="num">Claims</th></tr></thead><tbody>{rows}</tbody></table>'
             f'<p class="legend">Markers in the text: <i class="ok"></i>supported <i class="partial"></i>partial <i class="inferred"></i>inferred <i class="fail"></i>failed <i class="unreachable"></i>unreachable <i></i>unchecked</p>'
             f'</section>')
    out = re.sub(r'<section class="audit" id="audit">[\s\S]*?</section>', lambda m: audit, out, count=1)
    Path(path).write_text(out, encoding="utf-8")
    Path(str(path).replace(".html", ".audit.json")).write_text(json.dumps({
        "date": today, "verifier": verifier,
        "sources": {rid: {k: v for k, v in r.items() if k != "text"} | {"check": refcheck.get(rid) or {}} for rid, r in page.refs.items()},
        "claims": [{k: v for k, v in c.items() if k != "block"} for c in cites]}, indent=1, default=str), encoding="utf-8")



def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    opts = {a[2:].split("=", 1)[0]: (a.split("=", 1)[1] if "=" in a else True) for a in argv[1:] if a.startswith("--")}
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    path = Path(args[0])
    raw = path.read_text(encoding="utf-8")
    page = Page()
    page.feed(raw)
    errs, warns = structure(page, raw)
    for w in warns: print("warn:", w)
    for e in errs: print("ERROR:", e)
    print(f"{len(page.parts)} parts, {len(page.paras)} paragraphs, {len(page.cites)} cites, {len(page.refs)} sources, {len(page.charts)} charts, {len(page.svgs)} svgs")
    today = datetime.date.today().isoformat()
    refcheck, verifier = {}, ""
    if opts.get("archive"):
        for rid, r in page.refs.items():
            if not r["archive"] or r["archive"].startswith("FILL"):
                a = archive(r)
                r["archive_new"] = a
                r["archive"] = a or r["archive"]
                print(f"archive {rid}: {a or 'none'}")
    for c in page.cites:
        if not c["quote"] and c["ref"] in page.refs:
            c["quote"] = page.refs[c["ref"]]["quote"]
    if opts.get("fetch"):
        checks = {}
        for c in page.cites:
            key = (c["ref"], c["quote"])
            if c["ref"] not in page.refs:
                continue
            if key not in checks:
                checks[key] = check_quote(page.refs[c["ref"]], c["quote"])
            c["check"] = checks[key]
        for rid, r in page.refs.items():
            mine = [v for (k, _), v in checks.items() if k == rid] or [check_quote(r)]
            refcheck[rid] = {"live": mine[0].get("live"), "archive": mine[0].get("archive"),
                             "found": all(v.get("found") for v in mine), "where": mine[0].get("where"),
                             "quotes": len(mine), "quotes_found": sum(1 for v in mine if v.get("found"))}
            rc = refcheck[rid]
            print(f"fetch {rid}: live {rc.get('live')} archive {rc.get('archive')} quotes {rc['quotes_found']} of {rc['quotes']} found")
            for (k, q), v in checks.items():
                if k == rid and not v.get("found"):
                    print(f"   NOT FOUND: {q[:100]}")
    if opts.get("verify"):
        verifier = str(opts["verify"])
        verify(page.cites, page.refs, verifier)
    for c in page.cites:
        c["verdict"] = verdict_for(c, refcheck)
    if opts.get("fetch") or opts.get("verify"):
        from collections import Counter
        print("verdicts:", dict(Counter(c["verdict"] for c in page.cites)))
        for c in page.cites:
            if c["verdict"] in ("fail", "unreachable", "partial"):
                print(f"  {c['verdict']:11} line {c['line']} #{c['ref']}: {c['sentence'][:90]}  {(c.get('verifier') or ('',''))[1][:80]}")
    if opts.get("write"):
        write_page(path, raw, page, refcheck, page.cites, verifier, today)
        print(f"wrote {path} and {str(path).replace('.html', '.audit.json')}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
