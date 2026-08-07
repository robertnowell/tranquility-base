
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
5. **One session in the app layer at a time** (Sources/TranquilityApp/). Core
   and tools/ parallelize safely; the panel does not.
6. **Every merge to main is followed by `scripts/relaunch.sh`.** Merging is not
   deploying: the app is built locally into /private/tmp/tb-clean, so main can be
   correct while the thing in the menu bar is several merges behind. That gap is
   how a merged microphone fix sat unrunning while the microphone kept failing
   (07 Aug). The script is the only relaunch path — it resolves against
   origin/main, refuses a dirty worktree, and stops the old instance before
   building, because two instances race for one global hotkey.
