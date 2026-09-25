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
    return cfg["themes"]["editorial"]


def resolve(session=None, brand=None):
    cfg = load()
    t = dict(theme_for_brand(brand, cfg))
    if session:
        session = full_session(session)
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
    out = [f"/* {t['nameplate']} · theme {t['id']}"
           + (f" · agent {t['_session']}" if t["_session"] else "") + " */",
           block(":root", t, VARS)]
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


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    brand = None
    if "--brand" in flags:
        sys.exit("hq-theme: use --brand=NAME")
    for f in flags:
        if f.startswith("--brand="):
            brand = f.split("=", 1)[1]
    session = args[0] if args else None
    if not session and not brand:
        print("usage: hq-theme <session-id> [--brand=NAME] [--json]", file=sys.stderr)
        return 2
    try:
        t = resolve(session, brand)
    except UnknownSession as e:
        print(f"hq-theme: {e}", file=sys.stderr)
        return 1
    print(json.dumps(t, indent=2) if "--json" in flags else css(t))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
