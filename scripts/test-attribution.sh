#!/bin/bash
#
# The standing adversarial set for anything that decides WHO WROTE A PAGE.
#
# Every attribution failure this archive has had came from a rule that read a
# mention as an act: a command that quotes `cat >`, a page that quotes
# `data-tb-agent`, a file that merely changed recently. Six mechanisms since
# 16 Aug, two of them shipped and reverted inside an hour on 03 Sep — both of
# which these cases would have caught in seconds, and both of which were written
# only AFTER the damage.
#
# So the cases live here, they run in preflight, and any future rule about
# ownership has to pass them before it ships. Add a case whenever a new way of
# being wrong is found; never delete one.
set -uo pipefail
cd "$(dirname "$0")/.."

HOOK="hooks/artifact-hook.sh"
[ -r "$HOOK" ] || { echo "✗ $HOOK missing"; exit 1; }

pass=0; fail=0
ME="0d04e845-65ff-488f-983c-58f371d661ed"
MINE="$HOME/Documents/agents/0d04e845"
THEIRS="$HOME/Documents/agents/4394c0ec"

# The predicate, lifted out of the hook and exercised directly. Testing the
# extracted function rather than the whole hook keeps this fast and hermetic —
# no records written, no files stamped, nothing to clean up afterwards.
check() {                       # check <name> <expect writes: yes|no> <command>
  local name="$1" want="$2" cmd="$3" got
  got=$(HOOK="$HOOK" CMD="$cmd" python3 - <<'PY'
import os, re, sys
src = open(os.environ["HOOK"]).read()
i = src.index("def _written_paths(cmd):")
j = src.index("\n\n", src.index("return [f for f", i))
ns = {"re": re, "os": os}
exec(src[i:j], ns)
print("yes" if ns["_written_paths"](os.environ["CMD"]) else "no")
PY
)
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %-42s %s\n' "$name" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-42s got %s, want %s\n' "$name" "$got" "$want"
  fi
}

# A real page has to exist for the "and the file is on disk" half to be testable.
mkdir -p "$MINE" 2>/dev/null
REAL="$MINE/.attribution-probe.html"
printf '<!doctype html><title>probe</title>' > "$REAL"
trap 'rm -f "$REAL"' EXIT

echo "→ what counts as writing a page"
check "heredoc into my own directory"  yes "cat > $REAL <<'EOF'"$'\n'"x"$'\n'"EOF"
check "tee into my own directory"      yes "tee -a $REAL < in"
check "cp into a directory"            yes "cp build.html $REAL"

echo "→ what does NOT, however much it looks like it"
check "grep a page"                    no  "grep -o foo $REAL | head -1"
check "open a page"                    no  "open $REAL"
check "ls the tree"                    no  "ls ~/Documents/agents | head"
check "echo with a stderr redirect"    no  "echo hi 2>/dev/null; ls $REAL"
check "code that quotes a redirect"    no  "python3 <<PY"$'\n'"re.search(r'(cat|tee)\\s*>+', s)"$'\n'"p='$REAL'"$'\n'"PY"
check "a write to a path that is gone" no  "cat > $THEIRS/never-existed.html <<EOF"$'\n'"x"$'\n'"EOF"

echo
if [ "$fail" -eq 0 ]; then
  echo "✓ attribution: $pass case(s), no rule reads a mention as an act"
  exit 0
fi
echo "✗ attribution: $fail of $((pass + fail)) case(s) failed — a rule is guessing again"
exit 1
