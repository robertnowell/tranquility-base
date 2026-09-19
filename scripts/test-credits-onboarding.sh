#!/bin/bash
# Real Setup view with fixture services, before AppDelegate or live state exists.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain)" ]; then
  echo "Refusing to launch the credits drill from a dirty tree." >&2
  exit 1
fi
CREDITS_UI_BIN="$(swift build --show-bin-path)/TranquilityApp"
python3 - "$CREDITS_UI_BIN" <<'PY'
import os
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="tb-credits-ui-") as scratch:
    env = dict(os.environ, VOICE_DISPATCH_SUPPORT_DIR=scratch + "/support",
               TB_AGENTS_ROOT=scratch + "/agents")
    try:
        result = subprocess.run([sys.argv[1], "--selftest-credits-onboarding"],
                                env=env, timeout=30, text=True, capture_output=True)
    except subprocess.TimeoutExpired:
        sys.exit("Credits onboarding UI timed out")
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr, file=sys.stderr, end="")
    sys.exit(result.returncode)
PY
