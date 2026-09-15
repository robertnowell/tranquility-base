#!/bin/bash
# Audit exactly one committed checkout. No remote fetch, branch-freshness gate,
# or empty-diff shortcut: candidate selection belongs to the caller/merge gate.
# Usage: scripts/audit-source.sh <full-commit-sha>
set -euo pipefail
cd "$(dirname "$0")/.."

EXPECTED_COMMIT="${1:-}"
if [ "$#" -ne 1 ] || [[ ! "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "usage: scripts/audit-source.sh <full-commit-sha>" >&2
  exit 1
fi

verify_checkout() {
  if [ "$(git rev-parse HEAD)" != "$EXPECTED_COMMIT" ]; then
    echo "✗ audit checkout differs from expected commit $EXPECTED_COMMIT" >&2
    exit 1
  fi
  if [ -n "$(git status --porcelain)" ]; then
    echo "✗ audit checkout is dirty; commit changes before auditing" >&2
    git status --short >&2
    exit 1
  fi
}
verify_checkout
echo "→ source audit $EXPECTED_COMMIT"

# Exercise the boundary with disposable repositories and stubbed build tools.
python3 scripts/tests/test_source_audit.py

# Cheap, and it catches a class the panel's own drills cannot: a bare modifier
# glyph in text a human reads. The existing drill guards ONE string; this
# guards every string, which is what the 26 Aug ruling actually asked for.
echo "→ key names"
python3 scripts/check-key-names.sh

# Same shape, different rule: no em dashes in copy a human reads in the
# product. Added 27 Aug after one shipped to a card and the rule turned out
# to have been fixed by hand once already (copy/no-em-dashes-and-a-tooltip).
echo "→ house copy"
python3 scripts/check-house-copy.sh

# Same shape again, but this one guards memory rather than prose. An AEDesc
# borrowed from NSAppleEventDescriptor that we copy and dispose ourselves is a
# double free, and a double free does not crash where it is written: the Aug 26
# to Aug 29 crash corpus blamed GRDB, SQLite, Swift metadata and SwiftUI in
# turn before the real line was found. Cheap to check, expensive to miss.
echo "→ borrowed descriptors"
python3 scripts/check-borrowed-descriptors.sh

# And the provider seam's rule 3 (13 Sep, docs/rulings/ruling-the-provider-seam.md):
# every compatibility shim carries a dated removal comment. Same shape as the
# three above, and the only one of the ten rules a grep can answer -- rule 5,
# "every declared capability is read by production code", is a test instead
# because it has to read Swift rather than comment text.
echo "→ compat comments"
python3 scripts/check-compat-comments.sh

# And the one grep that keeps the grid honest about time (15 Sep): a row's
# `lastActivity` is the conversation's clock, never the file's. #458 shipped
# the other choice and Remote Control's bookkeeping lines reordered the panel
# by the next afternoon.
echo "→ row dates"
python3 scripts/check-row-dates.sh

echo "→ notarization log parser"
# Anything that decides WHO WROTE A PAGE runs against the adversarial set
# first. Both attribution regressions of 03 Sep would have died here in seconds;
# both were written after the damage instead.
scripts/test-attribution.sh

scripts/test-notary-log-parser.sh

# The release's last line, which is where 0.3.1053 died with a signed,
# notarized, stapled, fully audited DMG beside it. Every check between here and
# there passed; the one that failed was a retry loop that could not retry.
echo "→ release tag verification"
scripts/test-release-tag-verification.sh
scripts/test-debug-symbols.sh

echo "→ building"
swift build 2>&1 | grep -E "error:|warning: .*never used" || true
swift build >/dev/null

echo "→ isolated Past Agents search UI"
scripts/test-past-agents-search.sh

echo "→ testing"
# Captured, never piped. `... | grep -q ...` under `set -o pipefail` reports a
# FAILED pipeline on success: grep exits the moment it matches, the writer takes
# SIGPIPE, and pipefail faithfully reports that non-zero. It cost one false
# "tests failed" on a green tree — a check that cries wolf gets deleted, so it
# is worth the extra variable.
#
# That was fixed HALF WAY the first time: the run was captured into a variable,
# and then the variable was piped into `grep -q` anyway, which is the same race
# one line further down. It reappeared on 09 Aug the moment the suite grew — the
# first "with 0 failures" sits near the top of 68KB of output, so grep matched
# and exited while printf still had most of it to write, and preflight reported
# "tests failed (exit 0)" on a tree where all 277 passed. Under `bash -x` it
# passed, which is the signature of a race and cost a while to see.
#
# So: no pipe at all. Bash can test a substring without spawning anything, and
# a check with no subprocess has no pipeline to fail.
#
# Two invocations, not one — found 24 Aug on a new machine (App-lane P9): a
# bare `swift test` here silently runs ONLY the Swift Testing suites and
# skips every XCTestCase-based test with no error, no non-zero exit, nothing
# — 31 tests reported as green while 881 XCTestCase tests never ran. Passing
# `--enable-xctest --disable-swift-testing` is what actually forces the
# XCTest bundle to run; the default/both-enabled invocation reliably drops
# it on this toolchain. `arch -arm64e` because plain `swift`/`swift test`
# resolve to the x86_64 slice in this shell, which cannot dlopen the
# arm64e-only XCTest bundle at all. Both frameworks are checked separately
# so a silent zero in either one is a hard failure, not a quiet pass.
#
# The exit STATUS is the verdict; the summary line is a corroborating check that
# the run actually happened rather than dying before it reached the tests.
# Through scripts/test.sh, which runs both invocations AND refuses to report
# success unless each half cleared a floor. The two-invocation mechanism
# was this file's, found at App-lane P9; the floor is what stops an
# "Executed 0 tests, with 0 failures" from reading as green.
TEST_OUT=$(scripts/test.sh 2>&1) && TEST_STATUS=0 || TEST_STATUS=$?
if [ "$TEST_STATUS" -ne 0 ]; then
  echo "✗ tests failed (exit $TEST_STATUS)" >&2
  # The failing ASSERTIONS, not the compiler's source-context lines. `XCTAssert`
  # also matched the " 65 |   XCTAssertTrue(" context the compiler prints under
  # a warning, and twenty of those from the build phase pushed every real
  # failure off the bottom of a CI log (PR #299: three lines, seven times,
  # and not one of them the failure).
  # A CRASH IS NOT AN ASSERTION, and the patterns above could only see the
  # second. A `fatalError` or a force-unwrapped nil kills the xctest process,
  # so swift test reports "exited with unexpected signal code 5" and never
  # prints "Test Case ... failed" at all. The grep matched nothing, the log
  # said "✗ tests failed (exit 1)" and stopped, and finding out why cost a
  # full CI round trip (14 Sep, PR #423).
  #
  # `unexpected signal` and `Fatal error` are what a crash actually prints.
  FAILURE_LINES=$(printf '%s\n' "$TEST_OUT" | grep -E "✗|: error: |error: -\[|Test Case .* failed|Test Suite .* failed|unexpected signal|Fatal error|Crash:|couldn.t be loaded|incompatible architecture|recorded an issue" \
    | grep -v " warning: " | head -40 || true)
  if [ -n "$FAILURE_LINES" ]; then
    printf '%s\n' "$FAILURE_LINES" >&2
  else
    # Decide from what the filter actually emitted. A second, broader pattern
    # can match a reason that the first discarded, leaving an empty failure log.
    echo "  (no recognised failure line; the end of the run follows)" >&2
    printf '%s\n' "$TEST_OUT" | tail -40 >&2
  fi
  exit 1
fi
printf '%s\n' "$TEST_OUT" | grep -E "^✓ [0-9]+ XCTest" | tail -1 | sed 's/^✓/ /'
echo "✓ build clean, tests green"

# The app target is intentionally identical between Dev and Prod, while the
# packaging envelope must be intentionally different. This builds both from
# this checkout and guards both halves of that contract, including the exact
# local-signature-at-the-Prod-path regression that reset TCC grants.
echo "→ Dev/Prod packaging lanes"
scripts/test-dev-lanes.sh

# --- the drills that were never actually wired to anything --------------------
#
# Found in the arc's closing audit (24 Aug): the arc's own rule 4 requires
# "the drills" — swift test, scripts/test-dispatch-tmux.sh, --selftest-hud —
# on every landing, but this file only ever ran the first. The other two were
# real, working, human-run-when-remembered scripts with no gate behind them:
# a regression in either could ship and nothing here would catch it before
# someone noticed by hand. Worse for Codex specifically — test-codex-
# lifecycle.sh is the ONLY thing in this repo that exercises a real Codex
# session end to end, and it wasn't run by this script even once.
#
# test-dispatch-tmux.sh is a hard gate: it drives its own tmux server on a
# dedicated socket (tbdrill-<pid>), so it stays correct whether or not a real
# Tranquility Base instance is running alongside it.
echo "→ tmux dispatch drill"
scripts/test-dispatch-tmux.sh

# --- the palette owns every colour --------------------------------------------
#
# StateLegend.swift already carries a grep contract in writing, for glyphs: the
# state characters are "defined here and nowhere else in this module". Colour
# earns the same rule, and earned it the hard way — CheckView's tick was a
# hardcoded near-white, correct against the old dark green and 1.88:1 against the
# new one. An invisible checkmark, in one state, discoverable only by hitting
# that state at runtime.
#
# The contrast drill cannot catch that class: it measures Palette tokens, and a
# literal pasted into a view is by definition not one. This is the check that
# sees it, and it costs nothing.
echo "→ colour literals"
STRAY=$(grep -rn 'NSColor(srgbRed:\|NSColor(calibratedRed:\|NSColor(red:' \
  Sources/ --include='*.swift' | grep -v 'Sources/TranquilityApp/StateLegend.swift:' || true)
if [ -n "$STRAY" ]; then
  echo "✗ colour literal outside the Palette:" >&2
  printf '%s\n' "$STRAY" >&2
  echo "  Add it to StateLegend.Palette and reference it from there — a literal" >&2
  echo "  in a view is a colour no drill can measure and no theme can move." >&2
  exit 1
fi
echo "✓ every colour comes from the Palette"


verify_checkout
echo "✓ source audit passed for $EXPECTED_COMMIT"
