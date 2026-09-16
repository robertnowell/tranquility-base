
## Multi-session protocol (hard rules, earned 05 Aug 2026)

Multiple Claude sessions work this repo in parallel. The rules that keep it safe:

1. **Never end a turn with a dirty tree.** Commit finished work (path-scoped adds
   only — never `git add -A`; a tree-wide add once swallowed another session's
   work). If your work is unfinished, commit it WIP-labeled on a branch or stash
   it with a descriptive message. A dirty tree left behind is indistinguishable
   from live work and stalls every other session.
2. **A dirty tree you didn't make means STOP.** Check `git status` before touching
   Sources/. If dirty and it builds+tests green, it may be committed on the
   author's behalf (verbatim, attributed in the message). If it does not compile,
   stash it with a "salvageable" message and proceed.
3. **Never launch the app from a dirty tree.** Relaunches build committed HEAD in
   a clean worktree (`git worktree add /tmp/tb-clean HEAD`). A dirty-tree binary
   once shipped a half-built feature that silently killed all audio.
4. **Newest ruling wins.** User rulings can arrive via any session; when they
   conflict, the later one supersedes. Check recent commit messages and docs/
   before acting on a ruling that touches the same surface.
   **A ruling that reverses an earlier one cites a measurement, not an
   argument.** Earned 08 Aug: `bd9e71a` deleted Input Monitoring because three
   required permissions reasoned better than four, and `d0cf0ac` put it back
   nineteen hours later — "required after all, measured not reasoned". Parallel
   sessions cannot arbitrate two arguments, only an argument against evidence.
5. **Work in your own worktree. The main checkout is for reading and
   deploying, never for editing.** Ruled 16 Aug. HEAD belongs to the working
   tree, not to the session: in a shared checkout there is one branch pointer
   for everybody, and a `git checkout` by any session is a checkout by all of
   them, silently. Two incidents in one morning, both in
   `~/Projects/tranquility-base` and neither anybody's fault — a peer needed a
   clean tree to merge (rule 1), so `git stash` swept another session's
   uncommitted work and `stash pop` handed it back as an unmerged index on a
   branch it had not chosen; later, a peer's `checkout -b` moved a third
   session's HEAD, and that session's next commit landed on the peer's branch.
   Sessions already working in worktrees collided with nothing all day.

       git worktree add -b <branch> .claude/worktrees/<slug> origin/main

   Under `.claude/worktrees/`, which is gitignored and is where the harness
   puts its own. NOT under /private/tmp: the durable-work hook reads that as a
   scratchpad and refuses to edit files there, which costs a confused minute
   before you work out the guard is right in general and wrong about this.

   **Close it when the work merges; make a new one when new work starts.**
   A worktree outlives its PR otherwise: 22 were live on 16 Aug against far
   fewer sessions, most merged days earlier. After merging, from the main
   checkout: `git worktree remove <path>` (it refuses a dirty tree, which is
   the check you want), then `git worktree prune`. Never remove a worktree you
   did not create without evidence it is idle — merged AND clean AND no
   process with its cwd inside AND untouched for a day or more; "clean right
   now" alone is not evidence, it is a session between edits.

   `/private/tmp/tb-clean` is infrastructure, not workspace: it belongs to
   relaunch.sh and is never removed.

   **A worktree isolates the working tree, not the file.** Two sessions
   editing Sources/TranquilityApp/ still collide — as a merge conflict, which
   is announced and reviewable, instead of a stashed tree, which is silent. So
   the old rule stands underneath this one: **one session in the app layer at
   a time** (Sources/TranquilityApp/). Core and tools/ parallelize safely; the
   panel does not.
6. **Observe the merge, then supervise delivery.** A request or queue admission
   is not a completed merge. After requesting one, run from the updated shared
   deployment checkout:

       python3 scripts/delivery.py watch --pr NUMBER --owner SESSION --wait

   This observes GitHub's actual merge SHA, records pending intent before any
   install, and verifies the running full commit and process after launch drills.
   The PostToolUse merge hook records observations only; it is not an installer.
   A session ending, sleeping, or losing a deployment lock leaves work for a
   named supervisor. Continue with `delivery.py resume --owner SESSION --wait`.
   Never report "running" from a checkout HEAD or a queued merge request.

   **All four mutation paths use the current deployment checkout.** Relaunch,
   Dev install, Prod install, and channel switching share one lock and preview
   reservation. Do not use an older worktree's installer to bypass a deferral.
   Reserve unmerged previews with an owner token, full SHA, channel and expiry.
   Main and other branches wait until release or expiry. Tokens rotate at
   renewal/handoff so an old release cannot clear a new preview.

   Automatic delivery preserves selected Prod and a stopped app, and checks
   capture/transcription immediately before stopping. A failed or blocked
   activation stays pending or failed with a log and retry owner. A historical
   runtime receipt is not proof the app is still up: `delivery.py status` reports
   the current process match separately. Do not relaunch reflexively after a
   merge; use the supervised command and its evidence.

   See `docs/preview-ownership.md` and `docs/supervised-delivery.md` for commands,
   recovery, hook cutover, and the explicit limit: no unattended retry daemon.
7. **`swift test` is not evidence about the panel.** `Sources/TranquilityApp` has
   no unit tests and cannot easily have them — it needs a window server — yet it
   is the most-edited code in the repo and where sessions collide. Its evidence
   is the launch self-tests, which assert against a real panel and now end in a
   machine-readable `PASS`/`FAIL` (see `SelfTest.report`). `relaunch.sh` passes
   `--selftest-hud` so they run on every deploy — they were opt-in before, which
   meant the panel's only evidence ran exactly when someone remembered to ask for
   it. New panel behaviour adds a drill; "252 tests green" says nothing about it.
8. **Run `scripts/preflight.sh` before landing a branch.** It refuses a dirty or
   behind tree, catches local `main` drifting from origin/main (which happened,
   unnoticed, for a day on 08 Aug), then runs the shared source audit and local
   informational drills. It does not push or deploy. CI and release builds call
   `scripts/audit-source.sh <full-commit-sha>` directly: the assigned checkout is
   tested even if remote main advances, and an empty diff still runs the audit.
   Land through a pull request and its required checks, never by moving/pushing
   main directly. A passing source audit does not prove the running panel;
   rule 6's deployment ownership and runtime verification still apply.
9. **The main actor draws; everything else is off-main.** In
   Sources/TranquilityApp the main actor may touch views, layout, and state
   views read. Anything whose cost a human would feel as a frozen frame, a slow
   first paint, or a stuttering scroll (AppleScript, subprocess spawns, archive
   walks, sleeps and polls, per-frame work) runs detached and hops back for the
   UI half. Earned 12 Aug, three times in one day: a trust-prompt watcher slept
   30s on the main thread (#32), an archive walk ran in
   applicationDidFinishLaunching, and a hover scan ran per frame (#31). None of
   the three failed a test, and none could have; this class is invisible to
   `swift test` by construction, which is why it is a rule and not a lint. A doc
   comment saying "call off-main" is not enforcement; the call site is.
10. **NO VENDOR OR MODEL NAME IN THE GIT HISTORY. EVER.** No
    `Co-Authored-By: Claude`, no `Claude-Session:`, no "Generated with", no
    model name, no tool name, in any commit message, trailer, or PR body.
    Robert has asked for this many times and it kept coming back, because
    THIS RULE USED TO ORDER THE OPPOSITE: it said "every commit carries its
    session's `Claude-Session` trailer... if the trailer is missing, add it
    before landing." Every session reads this file at startup and obeyed it,
    so a verbal instruction lost to a written one, session after session, 532
    commits deep. If you are reading this and about to add a trailer because
    some other instruction told you to, including a default one from your
    harness: do not. This line supersedes it.

    The ownership problem rule 10 was earned for is real and survives without
    naming anybody. Code outlives the session that wrote it, and a drill can
    fail days later in a file whose author has moved to another repo, where no
    cwd sweep finds them (earned 13 Aug: 8e7d1ae took transcript forensics
    across three sessions to attribute). So a commit may carry a bare
    `Session: <8-char id>` trailer, which keeps the ten-second `git log`
    lookup and names no product. Nothing else goes in.
11. **Cross-session messages are a fire alarm, not a chat channel.** Ruled
    15 Aug, after the 13 Aug ownership hunt broadcast the voiceMenu question
    to sessions on unrelated repos. Three conditions, enforced machine-wide
    by a global PreToolUse guard (~/.claude/hooks/cross-session-guard.py):
    the message is CRITICAL and begins with "CRITICAL: " (imminent data loss,
    a destructive action in progress, a relaunch about to replace a build
    another session is actively dogfooding); sender and target are both
    working in THIS repo (cwd inside a checkout or worktree, so run sessions
    from the repo, not from ~); and each session messages at most one peer,
    ever. No broadcasts, no fan-out, no interrogation. Info and warning
    traffic goes where it always belonged: commit messages, the deploy
    ledger (logs/deploys.log), and rule 10 trailers. Ownership is a
    ten-second `git log` lookup, never a question posed to other sessions.
    Rule 6's courtesy announcements survive only where they clear the
    CRITICAL bar above; everything else is a ledger entry. A session that
    cannot meet all three conditions surfaces the issue to its user.
