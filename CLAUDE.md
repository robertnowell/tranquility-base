
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
