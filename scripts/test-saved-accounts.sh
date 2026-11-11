#!/bin/bash
# Account tiles with fixture profiles, before AppDelegate or live state exists.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain)" ]; then
  echo "Refusing to launch the saved-accounts drill from a dirty tree." >&2
  exit 1
fi
ACCOUNTS_UI_BIN="$(swift build --show-bin-path)/TranquilityApp"
python3 - "$ACCOUNTS_UI_BIN" <<'PY'
import os
import subprocess
import sys
import tempfile
import shutil

with tempfile.TemporaryDirectory(prefix="tb-saved-accounts-ui-") as scratch:
    env = dict(os.environ, VOICE_DISPATCH_SUPPORT_DIR=scratch + "/support",
               TB_AGENTS_ROOT=scratch + "/agents")
    try:
        result = subprocess.run([sys.argv[1], "--selftest-saved-accounts"],
                                env=env, timeout=30, text=True, capture_output=True)
    except subprocess.TimeoutExpired:
        sys.exit("Saved accounts onboarding UI timed out")
    shot = scratch + "/support/account-grid.png"
    if os.path.exists(shot): shutil.copyfile(shot, "/tmp/tb-saved-accounts-grid.png")
    print(result.stdout, end="")
    if result.returncode:
        print(result.stderr, file=sys.stderr, end="")
    sys.exit(result.returncode)
PY
