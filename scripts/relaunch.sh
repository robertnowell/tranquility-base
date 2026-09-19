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
. "$(dirname "$0")/lib/paths.sh"
. "$(dirname "$0")/lib/app-process.sh"
. "$(dirname "$0")/lib/deployment.sh"

REF="${1:-origin/main}"
CLEAN_WORKTREE="/private/tmp/tb-clean"
# Merged source deploys into a stable development identity. The published app
# is installed only from a release artifact or Sparkle, so a local build can no
# longer replace it and flip TCC's designated requirement.
export VD_APP_NAME="Tranquility Base Dev"
export VD_BUNDLE_ID="com.robertnowell.voice-dispatch.dev"
export VD_APP_CHANNEL="development"
export VD_UPDATES_ENABLED="false"
export VD_URL_SCHEMES="tranquilitybase voicedispatch tbdev"
export TB_FEED_URL="https://updates.tranquilitybase.to/dev-appcast.xml"
APP="$VD_APP_NAME.app"
APP_PATH="$(tb_bundle_dir debug "$CLEAN_WORKTREE")/$APP"
PROD_APP="/Applications/Tranquility Base.app"
PROD_WAS_RUNNING=0
APP_MUTATED=0
app_at_path_running "$PROD_APP" && PROD_WAS_RUNNING=1

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
  if [ "$APP_MUTATED" -eq 1 ] && ! app_running && [ -d "$APP_PATH" ]; then
    echo "→ interrupted mid-relaunch; bringing the app back up" >&2
    open "$APP_PATH" 2>/dev/null || true
  fi
}

automatic_activation_guard() {
  [ "${TB_DEPLOY_AUTOMATIC:-0}" = 1 ] || return 0
  if [ -n "${TARGET:-}" ] && [ "$(git rev-parse origin/main)" != "$TARGET" ]; then
    echo "deployment deferred: main advanced while preparing; build the newer target" >&2
    exit 75
  fi
  if app_at_path_running "$PROD_APP"; then
    APP_MUTATED=0
    echo "deployment deferred: Prod is selected; choose Dev explicitly before retrying" >&2
    exit 75
  fi
  if ! app_running; then
    APP_MUTATED=0
    echo "deployment deferred: app is stopped; automatic delivery does not undo Quit" >&2
    exit 75
  fi
}
tb_before_app_stop() {
  automatic_activation_guard
  tb_deployment_authorize relaunch "$TARGET" dev "$UNMERGED"
  APP_MUTATED=1
}
automatic_activation_guard
# Preparation owns only the build workspace. The child activation receives a
# leased, source-stamped app and matching checks, never the mutable build tree.
if [ "${1:-}" != --activate-prepared ]; then
  exec python3 scripts/prepare-dev.py relaunch "$REF"
fi
[ "$#" -eq 3 ] || { echo "invalid prepared activation" >&2; exit 1; }
TARGET="$2"
REF="$TARGET"
CLEAN_WORKTREE="$3"
APP_PATH="$CLEAN_WORKTREE/$APP"
python3 scripts/prepare-dev.py verify "$TARGET" "$CLEAN_WORKTREE"
# Refresh before owning the app lock. A stale automatic candidate is deferred.
git fetch -q origin
automatic_activation_guard
wait_for_microphone "before activation"
tb_deployment_lock
# If speech begins after the courtesy wait, defer immediately under the lock.
TB_MIC_GIVE_UP_AFTER=0
trap tb_deployment_unlock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 141' PIPE

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
  restore_if_down
  tb_deployment_unlock
}

# Resolve against the remote, not the local branch: a session that has merged but
# not pulled would otherwise relaunch the commit it already had.
# TARGET was pinned during preparation and refreshed before taking the lock.

UNMERGED=1
git merge-base --is-ancestor "$TARGET" origin/main && UNMERGED=0
tb_deployment_authorize relaunch "$TARGET" dev "$UNMERGED"
# Denial exits through unlock only; it must never launch a refused preview.
trap cleanup_and_restore EXIT
echo "→ target: $TARGET  $(git log -1 --format=%s "$TARGET")"
# Second ledger line, same pid: what the run above actually resolved to.
printf '%s pid=%s ref=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$TARGET" >> "$LEDGER"

# The script that deploys must BE the script being deployed.
#
# 29 Aug: this was run from the shared main checkout while that checkout sat 89
# commits and two days behind, so the copy that executed was the pre-00d31cf
# one, which deletes the app bundle BEFORE stopping the running instance. macOS
# does not keep a deleted binary's unfaulted pages alive, so the live app died
# with SIGBUS at whatever it next needed to page in: four crashes across two
# relaunches, in four unrelated symbols (NSAppleEventDescriptor dealloc,
# AGGraphGetCounter), which reads as memory corruption right up until you line
# them against the ledger. The fix had shipped two days earlier. Nothing
# checked that the fix was the thing running.
#
# Everything else here is already immune: the BUILD comes from $REF in a clean
# worktree, so it cannot be stale. Only the driver can be, and the driver is
# the half that deletes a bundle out from under a running process.
#
# Compares the file on disk, not the checkout's HEAD blob, so an uncommitted
# edit to this script is caught too rather than passing because the commit it
# came from happens to match.
SELF_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SELF_HASH=$(git hash-object "$SELF_PATH" 2>/dev/null || echo "")
REF_HASH=$(git rev-parse "$TARGET:scripts/relaunch.sh" 2>/dev/null || echo "")
if [ -n "$SELF_HASH" ] && [ -n "$REF_HASH" ] && [ "$SELF_HASH" != "$REF_HASH" ]; then
  if [ "${TB_ALLOW_STALE_SCRIPT:-0}" = "1" ]; then
    echo "⚠ this relaunch.sh differs from $REF; continuing because TB_ALLOW_STALE_SCRIPT=1" >&2
  else
    echo "✗ this relaunch.sh is not the one you are deploying." >&2
    echo "    running:   $SELF_PATH" >&2
    echo "    deploying: $REF ($TARGET)" >&2
    echo "  A stale driver has deleted the app bundle out from under a running" >&2
    echo "  instance before (29 Aug, four crashes). Update the checkout first:" >&2
    echo "    git -C $(git rev-parse --show-toplevel) pull --ff-only" >&2
    echo "  (TB_ALLOW_STALE_SCRIPT=1 overrides, for editing this script itself)" >&2
    exit 1
  fi
fi

# The build finished before this process acquired app ownership. Validate its
# pinned artifact again; a later build cannot change this app or its checks.
BUILT_SHA=$(/usr/libexec/PlistBuddy -c "Print :TBSourceCommit" "$APP_PATH/Contents/Info.plist")
[ "$BUILT_SHA" = "$TARGET" ] || { echo "✗ built source differs from reserved target" >&2; exit 1; }
"$CLEAN_WORKTREE/scripts/audit-dev.sh" "$APP_PATH"

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
  # Bundle id alone is not TCC identity. If the selected certificate changed,
  # replacing Dev would make every existing privacy grant look enabled but no
  # longer apply. Refuse before stopping either lane or deleting any bundle.
  OLD_REQUIREMENT=$(codesign -dr - "$INSTALLED" 2>&1 \
    | sed -n 's/^designated => //p' || true)
  NEW_REQUIREMENT=$(codesign -dr - "$APP_PATH" 2>&1 \
    | sed -n 's/^designated => //p' || true)
  if [ -n "$OLD_REQUIREMENT" ] && [ "$OLD_REQUIREMENT" != "$NEW_REQUIREMENT" ]; then
    echo "✗ Dev's signing requirement changed; leaving the installed app untouched." >&2
    echo "  Rotate deliberately with TB_ALLOW_DEV_IDENTITY_CHANGE=1 scripts/install-dev.sh." >&2
    exit 1
  fi
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
  # A merge should never evict somebody who deliberately selected the exact
  # production release for testing. Only stop the Dev path being replaced.
  automatic_activation_guard
  app_stop_path "$INSTALLED"
  APP_MUTATED=1
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

# Prod is a selected test lane, not an obstacle to a merge. The new Dev bundle
# is now installed and audited; leave the published process running exactly as
# it was. Dev's launch drills run the next time Dev is selected or deployed
# while active.
if [ "$PROD_WAS_RUNNING" -eq 1 ]; then
  echo "✓ Dev updated at $APP_PATH; active Prod left running"
  exit 0
fi

# Belt and braces: a no-op when the branch above already stopped it, and the
# real stop on a machine with no installed copy (the worktree-build path).
# Two instances racing for one global hotkey is its own bug, so the old one
# goes down immediately before the new one comes up, not before the build.
if [ "$APP_MUTATED" -eq 0 ]; then automatic_activation_guard; fi
app_stop
APP_MUTATED=1

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
# Once automatic delivery has requested launch, a later user Quit must stay
# stopped. Failure is recorded for the supervisor instead of resurrecting it.
if [ "${TB_DEPLOY_AUTOMATIC:-0}" = 1 ]; then APP_MUTATED=0; fi
sleep 4

if app_at_path_running "$APP_PATH"; then
  # "Running" was a pid check, and a pid proves a process, not a BUILD. Every
  # claim this script made about which ref was live was an inference from what
  # it had just installed — true in the ordinary case, and silent in exactly
  # the case worth catching (an install that did not replace the bundle, a
  # second copy launched from elsewhere, a stale app the restore trap brought
  # back). On 27 Aug that inference had to be re-derived by hand more than once.
  #
  # The bundle names its own commit now, so ask it.
  INSTALLED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "")
  SHORT_TARGET=$(git rev-parse --short "$TARGET" 2>/dev/null || echo "")
  if [ -n "$SHORT_TARGET" ] && [ -n "$INSTALLED_VERSION" ] \
     && [ "${INSTALLED_VERSION#*+}" != "$SHORT_TARGET" ]; then
    echo "✗ the app that is running is not the build this script made:" >&2
    echo "    installed bundle says $INSTALLED_VERSION, target is $SHORT_TARGET" >&2
    echo "  Something else replaced or launched it. Do not trust this deploy." >&2
    exit 1
  fi
  echo "✓ running $TARGET${INSTALLED_VERSION:+ (bundle $INSTALLED_VERSION)}"
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
  # Said in the channel too (6 Sep): a failed deploy used to be a line in a
  # terminal nobody was looking at. The same channel and poster the watchers
  # use; a Slack that is down does not change the exit code.
  . "$CLEAN_WORKTREE/scripts/lib/slack.sh"
  printf '%s\n' ":rotating_light: *Tranquility Base deploy of $REF: launch self-tests FAILED* on $(hostname -s). The build is running but a drill did not pass. \`scripts/check-selftests.sh\` has the verdicts; app.log has the rest." \
    | tb_slack_post "C0BR963MBJ9"
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

# Informational archive health runs after this receipt in prepare-dev.py, with
# its own 30-second deadline and log. It cannot keep app ownership occupied.

# A receipt is written under the same mutation lock only after a fresh process,
# full source stamp and passing launch drills have been established.
python3 scripts/delivery.py record-running --pid "$$" --lock-token "$TB_DEPLOY_LOCK_TOKEN" \
  --sha "$TARGET" --bundle "$APP_PATH" --launched-at "$LAUNCHED_AT"
