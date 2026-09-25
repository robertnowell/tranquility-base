#!/usr/bin/env python3
"""Where work lives, resolved from one place.

The address of the archive used to be an opinion held in thirty-five places:
skill markdown, shell scripts, python producers, a Swift constant, two
SessionStart hooks and a public README. Two of those disagreed about the
destination, and the disagreement is why 899 pages went one way and 95 went the
other. Nothing enforced either answer, so nothing broke loudly.

So the answer moves here, and every consumer asks instead of declaring:

    from hqconfig import roots
    roots.agents                  -> PosixPath('/Users/you/Documents/agents')

Shell callers get the same resolver through one subprocess:

    ROOT=$(hq-root agents)

Two bindings, one implementation, deliberately. Two implementations of "where
does this go" is the bug this file exists to end.

Config lives in $HQ_CONFIG or ~/.claude/hq.json, under a "roots" object. Any key
absent from the config falls back to DEFAULTS, so a machine with no config, or
with the config this skill shipped with, still resolves every name. That
fallback is the contract the published deep-research skill relies on: other
people have no hq.json and must keep getting ~/Documents/deep-research.
"""
import json
import os
import sys
from pathlib import Path

# The names a caller may ask for, and what they mean when nothing is declared.
#
# `legacy` is the pre-migration research directory. It stays a named root rather
# than becoming a literal in five scripts, because it has to keep resolving
# while the symlink farm is in place and has to be deletable from one line
# afterwards.
DEFAULTS = {
    "agents": "~/Documents/agents",
    "archive": "~/Documents/agents/_archive",
    "legacy": "~/Documents/deep-research",
    "out": "~/Projects/intranet",
    "notes": "~/Projects/port/content/notes",
}


def config_path():
    return Path(os.environ.get("HQ_CONFIG") or Path.home() / ".claude" / "hq.json")


def _declared():
    p = config_path()
    try:
        cfg = json.loads(p.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    declared = dict(cfg.get("roots") or {})
    # hq_root predates this file and is still the key publish.py reads for the
    # research corpus. Honour it as `legacy` so the two cannot drift apart while
    # the migration is half done.
    if "legacy" not in declared and cfg.get("hq_root"):
        declared["legacy"] = cfg["hq_root"]
    if "out" not in declared and cfg.get("out_dir"):
        declared["out"] = cfg["out_dir"]
    return {k: v for k, v in declared.items() if isinstance(v, str) and v}


class _Roots:
    """Attribute and item access over the resolved roots.

    Resolution happens per lookup rather than at import, so a long-running
    process picks up an edited config without a restart, and a test can point
    HQ_CONFIG somewhere else between calls.
    """

    def _resolve(self, name):
        if name not in DEFAULTS:
            raise KeyError(name)
        return Path(_declared().get(name, DEFAULTS[name])).expanduser()

    def __getattr__(self, name):
        try:
            return self._resolve(name)
        except KeyError:
            raise AttributeError(name) from None

    def __getitem__(self, name):
        return self._resolve(name)

    def __iter__(self):
        return iter(DEFAULTS)

    def items(self):
        return [(k, self._resolve(k)) for k in DEFAULTS]


roots = _Roots()


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        names = " | ".join(DEFAULTS)
        print(f"usage: hq-root <{names}>", file=sys.stderr)
        print(f"config: {config_path()}", file=sys.stderr)
        return 2
    try:
        print(roots[argv[1]])
    except KeyError:
        print(f"hq-root: unknown root {argv[1]!r}; known: {', '.join(DEFAULTS)}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
