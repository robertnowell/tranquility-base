#!/bin/bash
#
# Put the running app on the latest committed main, in one command.
#
# Why this exists: merging is not deploying. This app is built locally into a
# worktree that somebody has to rebuild by hand, so `main` can be correct for an
# hour while the thing in the menu bar is three merges behind — which is exactly
# how a microphone fix sat merged while the microphone kept failing (07 Aug).
# There is no pipeline to close that gap, so this is the pipeline.
#
# It is deliberately the ONLY relaunch path. CLAUDE.md rule 3 says relaunches
# build committed HEAD in a clean worktree; doing that by hand is four commands
# with two ways to get it subtly wrong (building a dirty tree, or building the
# right commit in the wrong worktree). Both have happened.
#
# Usage: scripts/relaunch.sh [ref]     (default: origin/main)

set -euo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/lib/app-process.sh"

REF="${1:-origin/main}"
CLEAN_WORKTREE="/private/tmp/tb-clean"
APP="Tranquility Base.app"
APP_PATH="$CLEAN_WORKTREE/.build/debug/$APP"

# Never exit leaving the app down.
#
# There is a window between stopping the old instance and launching the new one,
# and anything that kills this script inside it leaves no menu bar item at all —
# with nothing on screen to say why. Observed for real while testing: piping the
# output through `head` closed the pipe, SIGPIPE'd the script just after pkill,
# and the app simply vanished.
#
# Being one build behind is recoverable. Being gone is the failure this whole
# script exists to prevent, so put back whatever is on disk before leaving.
restore_if_down() {
  if ! app_running && [ -d "$APP_PATH" ]; then
    echo "→ interrupted mid-relaunch; bringing the app back up" >&2
    open "$APP_PATH" 2>/dev/null || true
  fi
}

# One deployer at a time (ruled 13 Aug, after the 05:06 race).
#
# Two concurrent relaunches interleave worse than they collide: one script's
# app_stop killed the other's freshly-drilled instance, and the other's
# restore_if_down then resurrected the app WITHOUT --selftest-hud — so the
# correct build ran unverified behind a log full of true lines from an
# instance that was already dead. The hotkey race is loud; this one is
# silent, which is why the second deployer is refused outright rather than
# queued. mkdir is the atomic primitive (macOS ships no flock); the pid
# inside lets a crashed deployer's lock be stolen instead of wedging
# deploys forever.
LOCKDIR="/tmp/tb-relaunch.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  HOLDER=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
  if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then
    echo "✗ another relaunch (pid $HOLDER) is mid-flight — refusing to stack a second." >&2
    echo "  Wait for its deploy note, then rerun if your ref still is not live." >&2
    exit 1
  fi
  echo "→ clearing a stale relaunch lock (holder ${HOLDER:-unknown} is gone)"
  rm -rf "$LOCKDIR"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    echo "✗ lost the lock race to another relaunch that started this instant." >&2
    exit 1
  fi
fi
echo $$ > "$LOCKDIR/pid"

# The deploy ledger: every run records WHO invoked it, before it does anything.
# Rule 6's announcement is a promise a session makes; this line is a fact the
# script makes, and the two must eventually agree. Earned 14 Aug: a deploy
# fired four seconds after a merge landed, no session claimed it, and
# attributing it required reflog forensics against dead pids — the same
# archaeology rule 10's commit trailers killed for code. $PPID's command line
# names a human shell or a Claude session's harness; CLAUDE_SESSION_ID names
# the session outright when the harness exports it.
# ONE ledger, wherever the script was invoked from. `logs/` is gitignored, so
# a path relative to the script is a path relative to the WORKTREE — and with
# a worktree per session (rule 5) that turns "every deploy is on the record"
# into "on one of N records", each holding only the deploys nobody else made.
# Measured 16 Aug, before the rule landed: 48 lines in the main checkout and
# zero in all 21 worktrees, because deploying had happened to be done from the
# same place every time. The lock above is already absolute for exactly this
# reason; the record it guards has to be too.
#
# Resolved through the COMMON git dir, which every worktree shares, so the
# ledger stays exactly where it has always been — the main checkout's
# logs/deploys.log, with its existing history — and every worktree appends to
# that one file instead of quietly starting its own.
#
# TB_DEPLOY_LEDGER overrides it for tests; never set it in normal use.
if [ -z "${TB_DEPLOY_LEDGER:-}" ]; then
  _common=$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")
  case "$_common" in /*) ;; *) _common="$PWD/$_common" ;; esac
  TB_DEPLOY_LEDGER="$(cd "$(dirname "$_common")" && pwd)/logs/deploys.log"
fi
LEDGER="$TB_DEPLOY_LEDGER"
mkdir -p "$(dirname "$LEDGER")"
printf '%s pid=%s ppid=%s invoker=%q session=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$PPID" \
  "$(ps -o command= -p "$PPID" 2>/dev/null | head -c 120)" \
  "${CLAUDE_SESSION_ID:-unset}" >> "$LEDGER"

# The lock releases on ANY exit, and restore_if_down still runs: holding the
# lock must never become a way to leave the app down.
cleanup_and_restore() {
  rm -rf "$LOCKDIR"
  restore_if_down
}
trap cleanup_and_restore EXIT INT TERM PIPE

# Resolve against the remote, not the local branch: a session that has merged but
# not pulled would otherwise relaunch the commit it already had.
git fetch -q origin
TARGET=$(git rev-parse --short "$REF")
echo "→ target: $TARGET  $(git log -1 --format=%s "$REF")"
# Second ledger line, same pid: what the run above actually resolved to.
printf '%s pid=%s ref=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$TARGET" >> "$LEDGER"

# Creating and validating the clean worktree now lives in scripts/build-clean.sh,
# so install.sh can do it too — it could not before, which is why a fresh clone
# hit an installer that refused and pointed back here. One copy, one behaviour.
# The dirty-tree refusal therefore lands after the capture-marker wait below
# rather than before it: on a dirty tree you now wait for the microphone before
# being told no. Refusing later is the acceptable half of not maintaining this
# block in two scripts.

# Never kill a live microphone.
#
# The recorder holds the whole utterance in memory and flushes once at key-up, so
# killing mid-sentence does not lose a file — it loses the words. That was
# survivable while a person chose the moment to relaunch. It stopped being
# survivable when a merge started firing this automatically, possibly from a
# session the speaker is not watching.
#
# The marker is written by Recorder.start and cleared by stop/abandon; it carries
# its start time so a crash cannot wedge relaunches forever (see CaptureMarker).
MARKER="$HOME/Library/Application Support/VoiceDispatch/capturing"
# Mirrors CaptureMarker.staleAfter, which this script cannot read because it is
# bash. The marker is re-stamped every CaptureMarker.heartbeat seconds for as
# long as the microphone is open, so age means "silence from the writer", not
# "length of the utterance". It was the second reading, at 180s, that let this
# script destroy a live four-minute capture on 10 Aug. Change both or neither.
STALE_AFTER=20
GIVE_UP_AFTER=120
waited=0
while [ -f "$MARKER" ]; do
  started=$(cat "$MARKER" 2>/dev/null || echo 0)
  case "$started" in ''|*[!0-9]*) started=0 ;; esac
  age=$(( $(date +%s) - started ))
  if [ "$started" -eq 0 ] || [ "$age" -ge "$STALE_AFTER" ]; then
    echo "→ ignoring a stale capture marker (${age}s old)"
    break
  fi
  if [ "$waited" -ge "$GIVE_UP_AFTER" ]; then
    # Refusing is the safe failure: the app keeps running its current build,
    # which is exactly what it was doing a second ago. Losing the utterance is
    # not recoverable; being one commit behind for another minute is.
    echo "✗ microphone still open after ${waited}s — not relaunching." >&2
    echo "  The app stays on its current build. Run this again when you're done." >&2
    exit 1
  fi
  [ "$waited" -eq 0 ] && echo "→ microphone is open; waiting for the utterance to finish"
  sleep 2
  waited=$(( waited + 2 ))
done

# BUILD FIRST, then stop, then launch.
#
# The old order stopped the app and then built, which left it down for the whole
# build — around forty seconds — and anything that killed this script in there
# left it down for good. The EXIT trap could not save it either, because
# bundle.sh `rm -rf`s the .app it is about to recreate, so for most of that
# window there was nothing on disk to reopen. Measured the hard way: a `| head`
# closed the pipe mid-build and the menu bar item simply went away.
#
# Building first inverts that. The app keeps running while the slow part happens
# and the window where it is down shrinks from the length of a build to the
# length of a launch. The cost is that bundle.sh replaces the bundle underneath a
# running process; that is safe here because this app loads nothing from its
# bundle after launch — it draws its whole interface programmatically — and the
# process is replaced seconds later anyway.
APP_PATH=$(scripts/build-clean.sh "$REF")

# Deploy INTO the installed copy when there is one.
#
# Once scripts/install.sh has run, /Applications holds the app the Dock,
# Spotlight and the login item all point at. Building here and opening the
# worktree copy instead would leave two bundles with one bundle id: the one you
# just built running now, and a stale one starting at your next login. So the
# built bundle replaces the installed one and everything downstream uses that
# path. No install, no change — the worktree copy stays the target, exactly as
# before, so this is safe on a machine that has never run the installer.
INSTALLED="/Applications/$APP"
if [ -d "$INSTALLED" ]; then
  # STOP FIRST. `rm -rf` on the installed bundle deletes the executable of a
  # process that is still running, and macOS does not keep a deleted binary's
  # pages alive: every page the live app has not already faulted in becomes
  # unreadable, and it dies with SIGBUS / KERN_PROTECTION_FAILURE at whatever
  # instruction happens to need one next.
  #
  # That is why the crash never looked like a deploy. Four reports on 26 Aug,
  # in four unrelated places — `swift_release`, `_getWitnessTable`, a
  # deduplicated symbol, `sqlite3FkRequired` — on two different threads, which
  # reads as memory corruption until you line them up against the ledger: one
  # crash TWO SECONDS after a deploy, and every one of the others within
  # minutes of one. The app was running with its own bundle deleted, and it
  # died the next time it ran code it had not run yet. Robert saw it as "the
  # app crashes after I reply", because a reply is exactly when it touches
  # pages it has not touched before.
  #
  # The old order was deliberate — see `app_stop`'s comment below, which wanted
  # the gap between stopping and starting kept short. That intent survives:
  # the BUILD still happens before any of this, so stopping here is still
  # "immediately before the new one comes up", just not after deleting the
  # binary out from under the old one.
  app_stop
  echo "→ updating the installed copy"
  rm -rf "$INSTALLED"
  cp -R "$APP_PATH" "$INSTALLED"
  xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
  if ! codesign --verify --deep --strict "$INSTALLED" 2>/dev/null; then
    # A copy that does not verify is a DIFFERENT app to macOS: every permission
    # would be re-prompted. Keep running the worktree build rather than install
    # something that would silently cost the user their grants.
    echo "✗ the installed copy does not verify — leaving it and using the worktree build" >&2
    INSTALLED=""
  fi
  [ -n "$INSTALLED" ] && APP_PATH="$INSTALLED"
fi

# Belt and braces: a no-op when the branch above already stopped it, and the
# real stop on a machine with no installed copy (the worktree-build path).
# Two instances racing for one global hotkey is its own bug, so the old one
# goes down immediately before the new one comes up, not before the build.
app_stop

echo "→ launching (with panel self-tests)"
LAUNCHED_AT=$(date +%s)
# --selftest-hud, every relaunch. The drills were opt-in, which meant the panel's
# only evidence ran exactly when someone remembered to ask for it — i.e. never in
# the loop that ships code. They run synchronously at startup, paint through
# every state with worst-case text, and clean up onto the idle grid, which is
# where launch lands anyway. One instance, so no hotkey race.
#
# --selftest-arm is deliberately NOT included: it needs the microphone and drives
# the real recorder and store. Opt in by hand when changing the arm path.
open "$APP_PATH" --args --selftest-hud
sleep 4

if app_running; then
  echo "✓ running $TARGET"
else
  echo "✗ did not stay up — check ~/Library/Application Support/VoiceDispatch/app.log" >&2
  exit 1
fi

# The self-tests, read rather than merely run.
#
# The panel is the most-edited code in the repo and the only layer `swift test`
# cannot reach, so "252 tests green" has never said anything about it. The drills
# that CAN speak for it have run at every launch since the beginning and nothing
# ever looked at the answer. Now the relaunch does.
#
# Reporting, not refusing. The app is already up on the new build by this point,
# and taking it back down over a failed drill would contradict the one rule this
# script exists to hold — never leave the app down. A loud non-zero exit is
# enough to stop a merge; the operator decides what to do about the app.
#
# The drills are asynchronous (one reports five seconds after the undo window),
# so give them room before reading.
# The verification scripts run from $CLEAN_WORKTREE, NOT from this script's
# own directory. This script executes from the shared checkout, which sits on
# whatever branch someone last left it on, while the app is built from the
# pinned ref in $CLEAN_WORKTREE — so "./scripts/…" verifies a deploy with
# tooling from an unrelated branch. That skew bit twice on 12 Aug: a stale
# check-selftests.sh produced a false "panel is stuck", and a checkout parked
# on an old branch silently skipped the freshly-landed canary. build-clean.sh
# has already put $CLEAN_WORKTREE on $REF by this point, so these copies are
# the deployed ref's own. (Residual gap, accepted: THIS file still runs from
# the checkout, so a change to relaunch.sh itself needs the checkout current —
# but the blast radius is now one file instead of every script it calls.)
sleep 6
if ! "$CLEAN_WORKTREE/scripts/check-selftests.sh" "" "$LAUNCHED_AT"; then
  echo "✗ the build is running, but its self-tests did not pass." >&2
  echo "  Fix or revert before landing this — the panel has no other coverage." >&2
  exit 1
fi

# The Claude Code contract, checked while we are already being loud.
#
# The app scrapes surfaces Claude Code never promised anyone (rendered TUI
# text, `agents --json`), and that coupling rots silently: the watcher's old
# "? for shortcuts" sentinel was dead for an unknown number of releases before
# anyone felt it as a 35s beach ball (12 Aug, PR #32). scripts/canary.sh
# re-verifies the contract at every deploy, so the next rot is a red line in
# this terminal rather than a symptom a human has to feel first.
#
# Same posture as the self-tests: reporting, not refusing. The app is already
# up; a moved contract means degraded launches, not a bad build. Exit 2 keeps
# it distinguishable from a self-test failure. TB_SKIP_CANARY=1 skips it in an
# emergency (e.g. Terminal automation unavailable in this context).
if [ "${TB_SKIP_CANARY:-0}" != "1" ]; then
  if ! "$CLEAN_WORKTREE/scripts/canary.sh"; then
    echo "✗ the build is fine, but Claude Code's contract moved — see above." >&2
    echo "  Re-verify SessionLauncher's sentinels / ClaudeAgentsCLI parsing." >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# The seam check. Unit tests cover each piece of the artifact→hub chain and
# every failure this month still slipped through, because each bug lived
# BETWEEN a hook, a log, a file and a rendered page. This asks the archive
# whether the pieces still add up: a page a session made is on that session's
# hub, a hub names its session, a page carries exactly one agent footer.
#
# Reporting, not refusing — same posture as the self-tests and the canary. It
# runs against real data that other sessions are writing while this runs, so a
# transient miss must not fail a good build; a persistent one shows up on
# every deploy until someone looks.
#
# The deploy builds ONLY the app product (bundle.sh: `--product TranquilityApp`),
# so `tbase` in the clean worktree is whatever a previous build happened to
# leave there — or absent. This gate shipped reading that stale binary, which
# printed the usage text and exited non-zero, so every deploy reported "the
# archive and the hubs disagree" while the archive was fine. Build the tool
# the gate runs, next to the gate that runs it.
( cd "$CLEAN_WORKTREE" && swift build --configuration debug --product tbase >/dev/null 2>&1 ) || true
if ! "$CLEAN_WORKTREE/.build/debug/tbase" doctor; then
  echo "✗ the build is fine, but the archive and the hubs disagree — see above." >&2
  echo "  \`tbase homebase <session-id>\` rewrites one hub; \`tbase doctor\` re-checks." >&2
fi
