#!/bin/bash
# Exercise the real manager event handler and orb without connecting live services.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain)" ]; then
  echo "Refusing to launch the manager drill from a dirty tree." >&2
  exit 1
fi
MANAGER_UI_BIN="$(swift build --show-bin-path)/TranquilityApp"
python3 - "$MANAGER_UI_BIN" <<'PY'
import os
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="tb-manager-ui-") as scratch:
    env = dict(os.environ, VOICE_DISPATCH_SUPPORT_DIR=scratch + "/support",
               TB_AGENTS_ROOT=scratch + "/agents")
    try:
        result = subprocess.run([sys.argv[1], "--selftest-manager-listening"],
                                env=env, timeout=30, text=True, capture_output=True)
    except subprocess.TimeoutExpired:
        sys.exit("Manager listening UI timed out")
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr, file=sys.stderr, end="")
    sys.exit(result.returncode)
PY
