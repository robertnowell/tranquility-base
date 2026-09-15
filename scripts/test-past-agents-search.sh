#!/bin/bash
# Run after building. This creates an isolated AppKit list, never a live app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain)" ]; then
  echo "Refusing to launch the search drill from a dirty tree." >&2
  exit 1
fi
SEARCH_BIN="$(swift build --show-bin-path)/TranquilityApp"
python3 - "$SEARCH_BIN" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run([sys.argv[1], "--selftest-past-search"],
                            timeout=30, text=True, capture_output=True)
except subprocess.TimeoutExpired:
    sys.exit("Past Agents search UI timed out")
print(result.stdout, end="")
if result.returncode:
    print(result.stderr, file=sys.stderr, end="")
sys.exit(result.returncode)
PY
