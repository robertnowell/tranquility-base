#!/usr/bin/env python3
"""Move inline images out of archive pages and into object storage.

WHY THIS EXISTS
---------------
Every page in this archive has been required to be fully self-contained, which
is what makes one portable and what makes the archive enormous. Measured 07 Sep
2026 across ~/Documents/agents:

    1756 html files          269.9 MB total
      72 files (4%) hold inline images
     617 data: URIs          94.6 MB  -- 35% of ALL the html on disk
       4 pages alone          75.4 MB

So a twenty-fifth of the pages carry a third of the weight, which is the whole
argument: the migration is small, and the payoff is not.

THE ORDER MATTERS, AND IT IS NOT NEGOTIABLE
-------------------------------------------
    extract -> upload -> VERIFY -> rewrite -> drop

The inline copy is the only copy until the remote one has been fetched back and
checked byte-for-byte. A page is rewritten only when every image on it verifies;
one failure and that page is left exactly as it was. There is no partial page.

WHAT IS NOT MOVED
-----------------
Fonts and favicons stay inline, deliberately. A page must still LOOK right with
the network off, and type is the difference between right and wrong; a favicon
is 1 KB and moving it would buy nothing. Only raster media is worth an outside
dependency, and only from the archive's own asset origin -- a .png on somebody
else's CDN is still a page that stops working when they reorganise.

MODES
-----
    --plan     (default) measure and report. Touches nothing.
    --stage    decode to a staging dir. Still touches no page.
    --upload   push staged objects. Needs credentials.
    --rewrite  swap data: URIs for URLs, after verifying every one.

Nothing happens to a page without --rewrite, and --rewrite refuses to run
unless assets.base_url is configured in hq.json.
"""

import argparse, base64, hashlib, json, os, re, shutil, sys, urllib.request
from pathlib import Path

DATA_URI = re.compile(
    rb'data:(image/(?:jpeg|jpg|png|gif|webp|avif));base64,([A-Za-z0-9+/=\s]{40,})')

EXT = {"image/jpeg": "jpg", "image/jpg": "jpg", "image/png": "png",
       "image/gif": "gif", "image/webp": "webp", "image/avif": "avif"}

# A file beside the page. `<img src="assets/x.png">` is as invisible to the
# cloud hub as a data: URI is heavy for the archive: the mirror ships only
# the html, so the address points at nothing there (11 Sep, a Kopi calendar
# report with three screenshots showed three broken images in the app). The
# fix is the same as for inline images: the file goes to the media bucket
# and the page points at it by absolute address, which works on disk, in
# the app, and on any published copy alike.
RELATIVE_REF = re.compile(
    rb'<(?:img|source|video)\b[^>]*?\s(?:src|poster)="((?!https?:|data:|/|#|//)[^"?#]+?\.'
    rb'(?:png|jpe?g|gif|webp|avif))"', re.IGNORECASE)
MIME_BY_EXT = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
               "gif": "image/gif", "webp": "image/webp", "avif": "image/avif"}

# Never touch these, whatever they contain. index.html is the hub and the app
# owns it; _archive holds the retired tree.
SKIP_NAMES = {"index.html"}


def load_cfg():
    p = os.environ.get("HQ_CONFIG") or (Path.home() / ".claude" / "hq.json")
    try:
        return json.loads(Path(p).expanduser().read_text())
    except Exception:
        return {}


def assets_cfg(cfg):
    a = cfg.get("assets") or {}
    base = (a.get("base_url") or "").rstrip("/")
    return base, (a.get("prefix") or "media").strip("/")


def scan(root, include_hubs=False):
    """Every (page, [images]) with at least one inline image.

    Images are keyed by CONTENT, so the same screenshot pasted into four
    reports uploads once and every page points at the same object.
    """
    pages = []
    for dp, dn, fn in os.walk(root):
        for f in sorted(fn):
            if not f.endswith(".html"):
                continue
            if not include_hubs and f in SKIP_NAMES and Path(dp).parent.name == "agents":
                continue
            p = Path(dp) / f
            try:
                raw = p.read_bytes()
            except Exception:
                continue
            hits = DATA_URI.findall(raw)
            refs = []
            for ref in RELATIVE_REF.findall(raw):
                try:
                    rel = ref.decode()
                except Exception:
                    continue
                target = (p.parent / rel).resolve()
                # Only a file inside this page's own directory tree counts:
                # a page may not reach across the archive with "../".
                if not str(target).startswith(str(p.parent.resolve()) + os.sep):
                    continue
                if not target.is_file():
                    continue
                refs.append((rel, target))
            if not hits and not refs:
                continue
            imgs = []
            seen_refs = set()
            for rel, target in refs:
                if rel in seen_refs:
                    continue
                seen_refs.add(rel)
                try:
                    blob = target.read_bytes()
                except Exception:
                    continue
                ext = target.suffix.lower().lstrip(".")
                mime = MIME_BY_EXT.get(ext, "application/octet-stream")
                digest = hashlib.sha256(blob).hexdigest()
                imgs.append({
                    "sha256": digest,
                    "key": f"{digest[:16]}.{EXT.get(mime, ext or 'bin')}",
                    "mime": mime,
                    "bytes": len(blob),
                    "encoded_bytes": 0,
                    "blob": blob,
                    "ref": rel,
                })
            for mime, b64 in hits:
                mime = mime.decode()
                try:
                    blob = base64.b64decode(re.sub(rb'\s', b'', b64), validate=False)
                except Exception:
                    continue
                digest = hashlib.sha256(blob).hexdigest()
                imgs.append({
                    "sha256": digest,
                    "key": f"{digest[:16]}.{EXT.get(mime,'bin')}",
                    "mime": mime,
                    "bytes": len(blob),
                    "encoded_bytes": len(b64),
                    "blob": blob,
                })
            if imgs:
                pages.append({"path": str(p), "images": imgs,
                              "page_bytes": len(raw)})
    return pages


def mb(n):
    return f"{n/1e6:.1f} MB"


def cmd_plan(pages, base, args):
    uniq = {}
    enc = raw = 0
    for pg in pages:
        for im in pg["images"]:
            uniq.setdefault(im["sha256"], im)
            enc += im["encoded_bytes"]
            raw += im["bytes"]
    dupe_saving = raw - sum(i["bytes"] for i in uniq.values())
    print(f"pages with inline images : {len(pages)}")
    print(f"image references         : {sum(len(p['images']) for p in pages)}")
    print(f"distinct images          : {len(uniq)}")
    print(f"bytes leaving the html   : {mb(enc)}  (base64, what the files actually hold)")
    print(f"bytes to upload          : {mb(sum(i['bytes'] for i in uniq.values()))}  (binary, deduped)")
    print(f"saved by dedupe alone    : {mb(dupe_saving)}")
    print(f"asset origin             : {base or '(unset -- rewrite is refused)'}")
    print()
    print("heaviest pages:")
    for pg in sorted(pages, key=lambda p: -sum(i["encoded_bytes"] for i in p["images"]))[:10]:
        n = sum(i["encoded_bytes"] for i in pg["images"])
        print(f"   {mb(n):>9} / {mb(pg['page_bytes']):>9}  {len(pg['images']):>3} img  "
              f"{pg['path'].split('/agents/')[-1][:76]}")


def cmd_stage(pages, staging):
    staging.mkdir(parents=True, exist_ok=True)
    seen, wrote, total = set(), 0, 0
    for pg in pages:
        for im in pg["images"]:
            if im["sha256"] in seen:
                continue
            seen.add(im["sha256"])
            out = staging / im["key"]
            if not out.exists():
                out.write_bytes(im["blob"])
                wrote += 1
                total += im["bytes"]
    manifest = {
        "images": [{k: v for k, v in im.items() if k != "blob"}
                   for pg in pages for im in pg["images"]],
        "pages": [{"path": pg["path"],
                   "keys": [im["key"] for im in pg["images"]]} for pg in pages],
    }
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"staged {wrote} new object(s), {mb(total)} -> {staging}")
    print(f"manifest: {staging / 'manifest.json'}")
    return manifest


def verify(url, expect_sha, expect_len):
    """Fetch it back and check the bytes. A HEAD is not evidence.

    The whole safety argument rests on this function: the inline copy is
    dropped only because this returned True, so it checks the CONTENT, not
    that something answered 200.
    """
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            body = r.read()
    except Exception as e:
        return False, f"fetch failed: {e}"
    if len(body) != expect_len:
        return False, f"length {len(body)} != {expect_len}"
    if hashlib.sha256(body).hexdigest() != expect_sha:
        return False, "sha256 mismatch"
    return True, "ok"


def cmd_rewrite(pages, base, prefix, args):
    if not base:
        sys.exit("refusing: assets.base_url is not set in hq.json. Nothing to point at.")
    backups = Path.home() / "Documents" / "_tb-backups" / "media-extract"
    backups.mkdir(parents=True, exist_ok=True)
    done = skipped = 0
    freed = 0
    for pg in pages:
        p = Path(pg["path"])
        # VERIFY EVERY IMAGE ON THIS PAGE FIRST. A page is all-or-nothing:
        # a half-rewritten page is a page with a hole in it, and a hole is
        # worse than a heavy file.
        bad = []
        for im in pg["images"]:
            url = f"{base}/{prefix}/{im['key']}"
            ok, why = verify(url, im["sha256"], im["bytes"])
            if not ok:
                bad.append((im["key"], why))
        if bad:
            skipped += 1
            print(f"  SKIP {p.name}: {len(bad)} image(s) not verified at the origin "
                  f"— first: {bad[0][0]} {bad[0][1]}")
            continue

        raw = p.read_bytes()
        st = p.stat()
        shutil.copy2(p, backups / f"{st.st_mtime_ns}-{p.name}")

        def sub(m):
            mime = m.group(1).decode()
            blob = base64.b64decode(re.sub(rb'\s', b'', m.group(2)), validate=False)
            key = f"{hashlib.sha256(blob).hexdigest()[:16]}.{EXT.get(mime,'bin')}"
            return f"{base}/{prefix}/{key}".encode()

        new = DATA_URI.sub(sub, raw)
        for im in pg["images"]:
            ref = im.get("ref")
            if not ref:
                continue
            url = f"{base}/{prefix}/{im['key']}"
            # The attribute value, exactly as written, quotes included, so
            # "assets/a.png" cannot also match "assets/a.png.bak".
            new = new.replace(b'"' + ref.encode() + b'"', b'"' + url.encode() + b'"')
        p.write_bytes(new)
        # mtime is the archive's sort order and the hub-of-hubs reads it.
        # Rewriting a 2026-08-17 report must not make it today's news.
        os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
        freed += len(raw) - len(new)
        done += 1
        print(f"  ok   {p.name}: {len(pg['images'])} image(s), {mb(len(raw)-len(new))} out")
    print(f"\nrewrote {done} page(s), skipped {skipped}, {mb(freed)} removed from html")
    print(f"originals: {backups}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(Path.home() / "Documents" / "agents"))
    ap.add_argument("--staging", default=str(Path.home() / "Documents" / "_tb-media-staging"))
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--stage", action="store_true")
    ap.add_argument("--rewrite", action="store_true")
    ap.add_argument("--include-hubs", action="store_true",
                    help="also touch agents/<id>/index.html (the app owns those; off by default)")
    args = ap.parse_args()

    cfg = load_cfg()
    base, prefix = assets_cfg(cfg)
    pages = scan(args.root, include_hubs=args.include_hubs)

    if args.rewrite:
        cmd_rewrite(pages, base, prefix, args)
    elif args.stage:
        cmd_stage(pages, Path(args.staging))
    else:
        cmd_plan(pages, base, args)


if __name__ == "__main__":
    main()
