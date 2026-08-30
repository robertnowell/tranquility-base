#!/usr/bin/env bash
#
# The one way to run this package's tests.
#
# `swift test` on its own is not it, for two reasons found on 24 Aug.
#
# 1. IT RUNS ON THE WRONG ARCHITECTURE, SILENTLY.
#    Sessions here run under a Rosetta shell (`uname -m` = x86_64) on Apple
#    Silicon hardware. The package builds arm64, so the XCTest bundle cannot be
#    loaded by an x86_64 `xctest`, and 842 of the 883 tests simply do not run.
#    The swift-testing runner is in-process and runs regardless.
#
# 2. THE LAST LINE IT PRINTS SAYS "passed".
#    The exit status IS honest — a broken load exits non-zero, and preflight
#    was right to refuse — but the final line of the output reads
#    "Test run with 41 tests in 4 suites passed", which is what a human or an
#    agent reading the tail concludes from. That is what happened: 95% of the
#    suite was dark and the terminal said passed. A truthful exit code that
#    nobody reads is not a signal.
#
# So this script does two things `swift test` will not: it picks the right
# architecture, and it REFUSES TO REPORT SUCCESS unless it can prove both
# halves of the suite actually ran. A count that silently shrinks is treated
# exactly like a failure, because it is one — that is the whole lesson of the
# reply-misroute this script was written alongside: a green signal answering a
# different question from the one being asked.
set -euo pipefail
cd "$(dirname "$0")/.."

# Raise these when the suite grows. They exist so that "the tests stopped being
# compiled in" cannot look like "the tests passed".
FLOOR_XCTEST=1158
FLOOR_SWIFT_TESTING=41

# Apple Silicon hardware under a translated shell: re-exec the test run native.
# `uname -m` reports the process PERSONALITY and is exactly what fooled us, so
# the question has to go to the HARDWARE, which Rosetta cannot lie about.
#
# It used to go there via `sysctl -n hw.optional.arm64`, and that is a PATH
# dependency wearing a hardware question's clothes: `sysctl` lives in
# /usr/sbin, the `2>/dev/null || echo 0` swallows a missing binary exactly the
# way it swallows an Intel Mac, and so any shell without /usr/sbin was quietly
# told this is not Apple Silicon. Agent shells are that shell -- the same
# missing-sbin class of PATH bug that had every launched pane exiting 127 on
# 24 Aug -- so the gate fell back to a plain `swift test`, which could not
# dlopen the arm64 bundle, and preflight reported the 24 Aug architecture
# failure on a tree where all 901 tests pass. A gate that fails green is worse
# than no gate: it teaches you to run the tests some other way.
#
# `arch -arm64e true` puts the same question to the hardware by attempting the
# only thing we actually want from the answer. It needs nothing but
# /usr/bin/arch, and it cannot be wrong by being absent: if it will not run,
# there was nothing to re-exec into.
#
# `env` as the no-op prefix, not an empty array: `"${RUNNER[@]}"` on an EMPTY
# array is an unbound-variable error under `set -u` in bash 3.2, which is what
# /usr/bin/env bash still is on macOS. Caught while proving the gate below —
# on a native arm64 shell, where no re-exec is needed, the script would have
# died before running a single test.
RUNNER=(env)
if [ "$(uname -m)" != "arm64" ] && arch -arm64e true 2>/dev/null; then
  RUNNER=(arch -arm64e)
  echo "→ shell is $(uname -m) on arm64 hardware; running tests under arch -arm64e"
fi

# TWO invocations, not one. Found independently by the App-lane session at P9
# on a different machine (945d499) and it is the stronger mechanism, so it wins
# here — rule 4, newest ruling, and this one cites a measurement: on that
# toolchain the both-enabled invocation drops the XCTest bundle silently, where
# on this one a single `arch -arm64` run happened to carry both. Asking for each
# framework explicitly is true on both machines; relying on the default is true
# on one of them. What this file adds on top is the floor — their version still
# passes an "Executed 0 tests, with 0 failures".
#
# Captured, never piped — see the long note in preflight.sh about pipefail and
# SIGPIPE. Same trap, same reason.
echo "→ swift test --enable-xctest"
OUT=$("${RUNNER[@]}" swift test --enable-xctest --disable-swift-testing 2>&1) \
  && STATUS=0 || STATUS=$?
echo "→ swift test --enable-swift-testing"
ST_OUT=$("${RUNNER[@]}" swift test --disable-xctest --enable-swift-testing 2>&1) \
  && ST_STATUS=0 || ST_STATUS=$?
OUT="$OUT
$ST_OUT"
[ "$ST_STATUS" -eq 0 ] || STATUS=$ST_STATUS

fail() {
  echo "✗ $1" >&2
  printf '%s\n' "$OUT" | grep -E "error:|XCTAssert|couldn't be loaded|incompatible architecture|recorded an issue" | head -20 >&2 || true
  exit 1
}

# --- gate 1: the bundle actually loaded ---------------------------------------
# BEFORE the exit status, deliberately. A failed load also exits non-zero, and
# "swift test exited 1" is a true sentence that tells you nothing. The specific
# diagnosis has to win, or the next person reads a number instead of a cause.
case "$OUT" in
  *"couldn't be loaded"*|*"incompatible architecture"*)
    fail "the XCTest bundle did not load — architecture mismatch, the 24 Aug failure" ;;
esac

# --- gate 2: the run itself ---------------------------------------------------
[ "$STATUS" -eq 0 ] || fail "swift test exited $STATUS"

# --- gate 3: both halves reported ---------------------------------------------
[[ "$OUT" == *"Test Suite 'All tests' passed"* ]] \
  || fail "no XCTest summary — the XCTest half did not run"
[[ "$OUT" == *"with 0 failures"* ]] \
  || fail "XCTest did not report '0 failures'"

XC=$(printf '%s\n' "$OUT" | grep -oE "Executed [0-9]+ tests" | tail -1 | grep -oE "[0-9]+" || echo 0)
ST=$(printf '%s\n' "$OUT" | grep -oE "Test run with [0-9]+ tests" | tail -1 | grep -oE "[0-9]+" || echo 0)

# --- gate 4: nothing quietly stopped running ----------------------------------
[ "$XC" -ge "$FLOOR_XCTEST" ] \
  || fail "only $XC XCTest tests ran, floor is $FLOOR_XCTEST — tests went missing, which is a failure"
[ "$ST" -ge "$FLOOR_SWIFT_TESTING" ] \
  || fail "only $ST swift-testing tests ran, floor is $FLOOR_SWIFT_TESTING — tests went missing, which is a failure"

echo "✓ $XC XCTest + $ST swift-testing = $((XC + ST)) tests, 0 failures"
if [ "$XC" -gt "$FLOOR_XCTEST" ] || [ "$ST" -gt "$FLOOR_SWIFT_TESTING" ]; then
  echo "  note: suite grew — raise FLOOR_XCTEST=$XC FLOOR_SWIFT_TESTING=$ST in scripts/test.sh"
fi
