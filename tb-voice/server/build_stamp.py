"""Which commit is answering.

Nothing recorded what was live on `tranquility-manager`, so a report from the
room ("it still cuts me off") could not be tied to a build, and two sessions
debugging on different days could not tell whether they were looking at the
same code. The deploy writes `build_stamped.py` beside this file with the sha
it built from; this module reads it, or says so when it is absent.

Absent is the normal case for a local run (`uv run bot.py`), where the working
tree is the answer and git can be asked directly.
"""

import os
import subprocess

_HERE = os.path.dirname(os.path.abspath(__file__))


def _generated() -> dict | None:
    try:
        from build_stamped import STAMP  # type: ignore[import-not-found]

        return dict(STAMP)
    except Exception:  # noqa: BLE001 — no stamp is a state, not an error
        return None


def _from_git() -> dict | None:
    try:
        out = subprocess.run(
            ["git", "-C", _HERE, "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=2,
        )
        if out.returncode != 0:
            return None
        dirty = subprocess.run(
            ["git", "-C", _HERE, "status", "--porcelain"],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
        return {"sha": out.stdout.strip() + ("-dirty" if dirty else ""), "where": "working tree"}
    except Exception:  # noqa: BLE001
        return None


def stamp() -> dict:
    """`{"sha": …, "where": …}`, or an honest unknown."""
    return _generated() or _from_git() or {"sha": "unknown", "where": "no stamp, no git"}


def line() -> str:
    s = stamp()
    return f"{s['sha']} ({s['where']})"
