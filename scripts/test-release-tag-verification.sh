#!/bin/bash
#
# The last line of a release, tested.
#
# 0.3.1053 was signed, notarized, stapled and through the full artifact audit
# when it died reading its own tag back:
#
#   ✗ release tag v0.3.1053-e19341a47 is a {"message":"Not Found", ... } object,
#     expected a commit
#
# A retry loop existed for exactly that. It could not fire, because `gh api`
# prints an error body to stdout on a 404 and the loop's only success test was
# "is the output non-empty". So it broke out on the first attempt holding the
# error as if it were data.
#
# That class of bug is invisible to every check this repo has: the script is
# correct shell, it runs, and the failure needs GitHub to briefly 404 a tag it
# has. Nothing can arrange that on demand, so `github_api` is stubbed and the
# loop is driven directly. `release.sh` is sourced with TB_RELEASE_LIB_ONLY=1,
# so what is tested is the shipped definition rather than a copy of it that
# would agree with the bug.

set -uo pipefail
cd "$(dirname "$0")/.."

COMMIT="1111111111111111111111111111111111111111"
OTHER="2222222222222222222222222222222222222222"
NOT_FOUND='{"message":"Not Found","documentation_url":"https://docs.github.com/rest/git/refs#get-a-reference","status":"404"}'

PASS=0
FAIL=0
check() {
  local name=$1 want=$2 got=$3
  if [[ "$got" == *"$want"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "✗ $name" >&2
    echo "    wanted: $want" >&2
    echo "    got:    $got" >&2
  fi
}

# One subshell per case: `fail` exits, and each case needs its own call counter.
# The stub writes its script into $BEHAVIOUR, one response per line, and the
# counter file survives the command substitution the real code runs it in.
run_case() {
  local behaviour=$1 target=${2:-$COMMIT}
  (
    export TB_RELEASE_LIB_ONLY=1
    # shellcheck disable=SC1091
    source scripts/release.sh

    TAG="v0.3.1053-e19341a47"
    TARGET="$target"
    REPO="robertnowell/tranquility-base"
    COUNTER=$(mktemp)
    printf '0\n' >"$COUNTER"
    printf '%s' "$behaviour" >"$COUNTER.script"

    # Every backoff, spent instantly. The test is about the decision the loop
    # makes, not about how long it waits, and a real backoff would put a minute
    # into preflight for nothing.
    sleep() { :; }

    github_api() {
      local n
      n=$(( $(cat "$COUNTER") + 1 ))
      printf '%s\n' "$n" >"$COUNTER"
      local line
      line=$(sed -n "${n}p" "$COUNTER.script")
      [ -n "$line" ] || line=$(tail -n 1 "$COUNTER.script")
      case "$line" in
        404) printf '%s\n' "$NOT_FOUND"; return 1 ;;
        commit) printf 'commit\t%s\n' "$COMMIT"; return 0 ;;
        elsewhere) printf 'commit\t%s\n' "$OTHER"; return 0 ;;
        annotated) printf 'tag\t%s\n' "$COMMIT"; return 0 ;;
      esac
    }

    verify_release_tag && echo "VERIFIED after $(cat "$COUNTER") call(s)"
  ) 2>&1
}

# THE REGRESSION. A tag that 404s twice and then resolves is the live failure,
# and the whole point of the loop. Before the fix this printed the 404 body as
# the tag's object type on call one.
check "a tag that arrives late is waited for" \
  "VERIFIED after 3 call(s)" \
  "$(run_case '404
404
commit')"

# And the error body never becomes data, however many times it comes back.
out=$(run_case '404')
check "a tag that never appears says so" "release tag v0.3.1053-e19341a47 does not exist" "$out"
# The exact sentence 0.3.1053 died with. It must never be reachable again: an
# error body read as a git object type is the bug, and "does not exist" above is
# the honest answer to the same input.
leak="the 404 body was not read as an object type"
case "$out" in *'is a {"message"'*) leak="LEAKED: $out" ;; esac
check "the 404 body is never read as an object type" \
  "the 404 body was not read as an object type" "$leak"

# The two real checks the loop exists to make still fail, and still fail with
# the sentence that names what is wrong. An annotated tag is a genuine problem
# (the release would point at a tag object, not the commit), and so is a tag
# that resolves to the wrong commit.
check "an annotated tag is refused" \
  "expected a commit" \
  "$(run_case 'annotated')"

check "a tag pointing elsewhere is refused" \
  "points to $OTHER" \
  "$(run_case 'elsewhere')"

# The success path must not spend a single retry when the answer is there.
check "a tag that is already there is read once" \
  "VERIFIED after 1 call(s)" \
  "$(run_case 'commit')"

if [ "$FAIL" -gt 0 ]; then
  echo "✗ release tag verification: $FAIL failed, $PASS passed" >&2
  exit 1
fi
echo "✓ release tag verification survives a 404 it is expected to survive ($PASS checks)"
