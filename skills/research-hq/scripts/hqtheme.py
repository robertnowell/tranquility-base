#!/usr/bin/env python3
"""What an agent's page should look like, resolved from its identity.

Three renderers held three stylesheets, which is why a hub and the report it
links to could not look like the same product. The tokens themselves were never
the problem: HomeBase.Theme has had thirteen of them, three themes, and a stable
per-agent ink for weeks. They were locked in one binary.

This reads the same table out of ~/.claude/hq-themes.json and answers the one
question a page author actually has, which is "what colours am I".

    hq-theme 0d04e845            -> a :root{...} block, ready to paste
    hq-theme 0d04e845 --json     -> the resolved tokens
    hq-theme --brand Kopi        -> a brand's tokens, no agent

TWO RULES CARRIED OVER FROM THE SWIFT, both learned the hard way.

The ink is DERIVED, never assigned: FNV-1a over the session id into eight chosen
inks, so the same agent is the same colour forever with no state to keep and
nothing to collide over. The hash must match the Swift byte for byte or a hub and
its own pages disagree, which is worse than no colour at all.

A BRAND theme keeps its own accent. Kopi's orange is the identity and an agent is
not one; there the mark of the agent is its nameplate and byline. Only the
unbranded house theme takes an agent ink.
"""
import json
import os
import sys
from pathlib import Path

THEMES = Path(os.environ.get("HQ_THEMES") or Path.home() / ".claude" / "hq-themes.json")


def load():
    try:
        return json.loads(THEMES.read_text())
    except (OSError, json.JSONDecodeError) as e:
        sys.exit(f"hq-theme: cannot read {THEMES}: {e}")


def agent_ink(session, inks):
    """FNV-1a, 64-bit, over the id's UTF-8 bytes.

    Stable across machines and launches, which a language's built-in string hash
    explicitly is not. The masking to 64 bits is what makes this identical to the
    Swift, where UInt64 wraps by definition.
    """
    h = 0xCBF29CE484222325
    for b in session.encode("utf-8"):
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return inks[h % len(inks)]


class UnknownSession(LookupError):
    """A slug with no full session id on record. Callers decide what that costs."""


ARTIFACTS = Path.home() / "Library/Application Support/VoiceDispatch/artifacts"


def full_session(sid):
    """The hash input is the FULL session id, never the 8-character slug.

    The hub directory is named by the slug, so the slug is what everything else
    holds and what a caller naturally reaches for. Hashing it produces a colour
    from the right palette that is simply the WRONG one: measured on 237 real
    hubs, 210 disagreed with what the app had already rendered. A plausible
    wrong answer is the dangerous kind, so this resolves a slug through the
    artifact log and refuses rather than guessing when it cannot.
    """
    if not sid or len(sid) > 8:
        return sid
    try:
        for f in sorted(ARTIFACTS.iterdir()):
            if f.name[:8] == sid and len(f.name) > 8:
                return f.name
    except OSError:
        pass
    # RAISE, do not exit. A CLI may end the process; a library called in a loop
    # over 300 agents may not, and this one did: the first unresolvable slug
    # killed the whole index build. The guard is right, the layer was wrong.
    raise UnknownSession(
        f"{sid!r} is a slug, not a session id, and no full id for it is on "
        f"record. Hashing the slug gives a colour from the right palette that "
        f"is the wrong one.")


def theme_for_brand(brand, cfg):
    key = (brand or "").lower()
    for needle, name in cfg.get("brand_map", []):
        if needle in key:
            return cfg["themes"][name]
    # THE FALLBACK IS THE HOUSE, AND IT IS NAMED. A brand nobody has recorded
    # gets the editorial theme, which is the right outcome and was already the
    # behaviour; what was missing was the sentence saying so. A silent fallback
    # reads as "this is Coframe's page" to a reader who cannot see the table.
    # Ruled 26 Sep 2026: the page wears the brand it is about, falls to the
    # house when the brand has none, and tells the reader which happened.
    t = dict(cfg["themes"]["editorial"])
    if key:
        t["_fallback_for"] = brand
    return t


BINDINGS = Path.home() / "Library/Application Support/VoiceDispatch/brands"


def bound_brand(session):
    """The brand this session decided on, if it has decided.

    Per agent session, by ruling: a session names its brand once, at its first
    page, and every later page it writes wears the same one without the agent
    having to remember. The binding is a file named by the full session id.
    """
    try:
        return (BINDINGS / session).read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def bind_brand(session, brand):
    BINDINGS.mkdir(parents=True, exist_ok=True)
    (BINDINGS / session).write_text(brand.strip() + "\n", encoding="utf-8")


def resolve(session=None, brand=None, bind=False):
    cfg = load()
    if session:
        session = full_session(session)
    if session and brand and bind:
        bind_brand(session, brand)
    if session and not brand:
        brand = bound_brand(session)
    t = dict(theme_for_brand(brand, cfg))
    if brand and not t.get("_fallback_for"):
        t["_brand_asked"] = brand
    if session and t.get("takes_agent_ink"):
        t["accent"] = agent_ink(session, cfg["agent_inks"])
    t.pop("_", None)
    if isinstance(t.get("type"), dict):
        t["type"] = {k: v for k, v in t["type"].items() if k != "_"}
    t["_session"] = session or ""
    t["_dark"] = ({k: v for k, v in cfg["dark"].items() if not k.startswith("_")}
                  if t.get("has_dark") else None)
    return t


VARS = ("bg", "paper", "ink", "heading", "muted", "faint", "line", "accent",
        "brand", "amber", "serif", "sans", "mono")


def css(t):
    def block(sel, src, keys):
        rows = "\n".join(f"  --{k}: {src[k]};" for k in keys if src.get(k))
        return f"{sel} {{\n{rows}\n}}"
    head = f"/* {t['nameplate']} · theme {t['id']}"
    if t.get("_fallback_for"):
        head += (f" · NO THEME ON RECORD FOR {t['_fallback_for']!r}, this is the house fallback."
                 f" Record one from a real source with: hq-theme --learn {t['_fallback_for']!r}"
                 f" --accent=#hex [--brand=#hex] --from='where the colour came from'")
    if t["_session"]:
        head += f" · agent {t['_session']}"
    out = [head + " */", block(":root", t, VARS)]
    # THE LANGUAGE, NOT ONLY THE INKS. A brand that carries a `type` block gets
    # its scale as variables and its rules as a comment, so a page set from
    # this output has the brand's hierarchy, not just its colours. Ratios are
    # against body_px; a theme without the block emits nothing here and pages
    # keep their own scale, which is the old behaviour exactly.
    ty = t.get("type")
    if isinstance(ty, dict):
        b = float(ty.get("body_px", 17))
        px = lambda r: f"{round(b * float(ty.get(r, 1)))}px"
        rows = {
            "body": f"{b:g}px", "body-lh": ty.get("body_lh", 1.2),
            "body-tracking": ty.get("body_tracking", "0"),
            "display": px("display_ratio"), "display-lh": ty.get("display_lh", 0.85),
            "display-weight": ty.get("display_weight", 500),
            "display-align": ty.get("display_align", "left"),
            "h2": px("h2_ratio"), "h2-lh": ty.get("h2_lh", 0.9),
            "h3": px("h3_ratio"), "small": px("small_ratio"),
            "measure": f"{ty.get('measure_px', 800)}px",
            "paragraph-gap": f"{ty.get('paragraph_gap_px', 20)}px",
        }
        out.append(":root {\n" + "\n".join(f"  --{k}: {v};" for k, v in rows.items()) + "\n}")
        rules = [f"   {k}: {ty[k]}" for k in ("labels", "separators", "mono", "accent") if ty.get(k)]
        if rules:
            out.append("/* language\n" + "\n".join(rules) + "\n*/")
    if t["_dark"]:
        out.append("@media (prefers-color-scheme: dark) {\n  "
                   + block(":root", t["_dark"], t["_dark"].keys()).replace("\n", "\n  ")
                   + "\n}")
    return "\n".join(out)


HEX = __import__("re").compile(r"^#[0-9a-fA-F]{6}$")


def learn(name, opts):
    """Record a brand's theme from a stated source, or say why not.

    "Automatically detect the target brand; if there is not one known, do a
    quick research on it, give a little information to the user, but not
    necessarily ask for permission" (ruled 26 Sep 2026). The research is the
    agent's (Kopi's brand record, the site, the logo); this is where it lands.

    Two rules from the table's own header. NEVER INVENT: a colour comes in as
    --accent/--brand from a named source, or is read off the site's declared
    <meta name="theme-color">; a frequency count of hexes in a stylesheet is
    not a brand. NO FACE WITHOUT ITS FILE: fonts the site names are recorded as
    fonts_seen for a human to ship later, never applied, because naming a font
    without its woff2 renders system sans and claims an identity the page does
    not carry. Everything else is the house editorial, so a learned brand is
    the house with its colour, which is exactly what a hub page should be.
    """
    import re, time, urllib.request
    src = opts.get("from") or ""
    accent = opts.get("accent")
    brandc = opts.get("brand")
    seen = []
    url = opts.get("url")
    if url:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 hq-theme"})
            html = urllib.request.urlopen(req, timeout=8).read(400_000).decode("utf-8", "ignore")
        except Exception as e:
            print(f"hq-theme: could not read {url}: {e}", file=sys.stderr)
            html = ""
        tc = (re.findall(r'<meta[^>]*name="theme-color"[^>]*content="([^"]+)"', html)
              + re.findall(r'<meta[^>]*content="([^"]+)"[^>]*name="theme-color"', html))
        tc = [c for c in tc if HEX.match(c.strip())]
        if tc and not accent:
            accent = tc[0].strip()
            src = src or f"theme-color declared at {url}"
        seen = list(dict.fromkeys(
            f.replace("+", " ").split(":")[0]
            for f in re.findall(r'fonts\.googleapis\.com/css2?\?family=([^&"\')]+)', html)))
    if not accent:
        print(f"hq-theme: {name!r} declares no colour I can read"
              + (f" at {url}" if url else "")
              + "; nothing recorded, pages stay on the house theme. Pass --accent=#hex "
                "--from='source' when a real source (a Kopi brand record, a logo) gives one.",
              file=sys.stderr)
        return 1
    if not HEX.match(accent) or (brandc and not HEX.match(brandc)):
        print("hq-theme: colours are six-digit hex (#ff6699)", file=sys.stderr)
        return 2
    if not src:
        print("hq-theme: --from='where the colour came from' is required; a token with no "
              "source is a guess with a :root block around it.", file=sys.stderr)
        return 2
    cfg = load()
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    t = dict(cfg["themes"]["editorial"])
    t.pop("_", None)
    t.update({"id": slug, "nameplate": name, "accent": accent, "brand": brandc or accent,
              "heading": brandc or t["heading"], "takes_agent_ink": False,
              "learned_from": src, "learned_at": time.strftime("%Y-%m-%d"),
              "fonts_seen": seen})
    cfg["themes"][slug] = t
    needle = name.lower()
    if [needle, slug] not in cfg.get("brand_map", []):
        cfg.setdefault("brand_map", []).append([needle, slug])
    tmp = THEMES.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(THEMES)
    print(f"recorded {name!r}: accent {accent}, brand {brandc or accent}, from {src}."
          + (f" Fonts seen, not applied (no file on disk): {', '.join(seen)}." if seen else "")
          + " Everything else is the house theme. Pages for this brand now wear it.")
    return 0


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    opts = {}
    for f in flags:
        if "=" in f:
            k, v = f[2:].split("=", 1)
            opts[k] = v
    for bare in ("--brand", "--learn", "--accent", "--from", "--url"):
        if bare in flags:
            sys.exit(f"hq-theme: use {bare}=VALUE")
    if "learn" in opts:
        return learn(opts["learn"], opts)
    brand = opts.get("brand")
    session = args[0] if args else None
    if not session and not brand:
        print("usage: hq-theme <session-id> [--brand=NAME] [--json]\n"
              "       hq-theme --learn=NAME --accent=#hex [--brand=#hex] --from='source' [--url=URL]",
              file=sys.stderr)
        return 2
    try:
        # A session that names a brand binds to it: its later pages resolve the
        # same brand from the session id alone (per agent session, ruled 26 Sep).
        t = resolve(session, brand, bind=bool(session and brand))
    except UnknownSession as e:
        print(f"hq-theme: {e}", file=sys.stderr)
        return 1
    print(json.dumps(t, indent=2) if "--json" in flags else css(t))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
