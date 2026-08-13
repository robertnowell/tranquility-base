
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
5. **One session in the app layer at a time** (Sources/TranquilityApp/). Core
   and tools/ parallelize safely; the panel does not.
6. **Every merge to main is followed by `scripts/relaunch.sh`.** Merging is not
   deploying: the app is built locally into /private/tmp/tb-clean, so main can be
   correct while the thing in the menu bar is several merges behind. That gap is
   how a merged microphone fix sat unrunning while the microphone kept failing
   (07 Aug). The script is the only relaunch path — it resolves against
   origin/main, refuses a dirty worktree, and stops the old instance before
   building, because two instances race for one global hotkey. It now also reads
   the launch self-tests and exits non-zero if any failed.
   **A relaunch is announced to the other sessions the moment it runs, with the
   ref it deployed.** There is one installed app; relaunching REPLACES whatever
   build is live, including a branch build another session's user is mid-way
   through acceptance-testing. Earned 12 Aug: a main relaunch (7bb2fe1) silently
   swapped out the ⌃⌃-fix branch build minutes before its dogfooding session —
   caught only because the deploying session sent a deploy note. Silent
   relaunches make the other session's evidence about a binary that is no
   longer running.
   **The note precedes the act, and one deployer runs at a time.** relaunch.sh
   holds a lockfile; a second concurrent run is refused outright, never
   interleaved. Earned 13 Aug at 05:06: two relaunches raced, one script's
   app_stop killed the other's freshly-drilled instance, and the other's
   restore trap resurrected the app bare, with no drills. The result was the
   correct build running unverified behind a green-looking log, which is
   quieter and therefore worse than a loud collision. Both times that race
   stayed visible, it was because the deploying session announced before
   acting, not after.
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
   unnoticed, for a day on 08 Aug), builds, tests, and then deliberately stops
   without pushing. Landing stays a decision, because with no CI and no panel
   tests, green is necessary and not sufficient. Move `main` with `git branch -f`
   rather than `git checkout` — the ref moves without touching a working tree
   another session may be editing.
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
10. **Every commit carries its session's `Claude-Session` trailer.** Code
    outlives the session that wrote it, and drills fail days later in files
    whose author has moved to another repo and another cwd, where no cwd
    sweep can find them. A trailer makes ownership a ten-second `git log`
    lookup. Earned 13 Aug: 8e7d1ae shipped without one, and while its
    voiceMenu drill held every deploy's gate red, attributing it took
    transcript forensics across three sessions to find an author who was
    alive the whole time. Hand-written commit messages are not exempt; if
    the trailer is missing, add it before landing.
