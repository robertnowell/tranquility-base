
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
6. **Merges to main deploy AUTOMATICALLY; the merging session verifies, and
   deploys by hand only when the robot didn't.** A global PostToolUse hook
   (`~/.claude/settings.json`) runs `scripts/relaunch.sh` when it sees a merge —
   discovered 14 Aug after a week of "phantom" deploys firing seconds after
   every merge with no session claiming them: the hook rode every session's
   merges and, being a shell script, could not announce. Ruled 14 Aug ("one
   deployer", the same single-writer principle as the panel arbiter): the hook
   IS the deployer. Do not run relaunch.sh reflexively after your merge — that
   is how the 14 Aug lock collisions happened, twice in one day, and most
   likely the 13 Aug 05:06 race too (hook vs session, not session vs session).
   Instead, after merging: within ~a minute, check `logs/deploys.log` gained
   your ref and /private/tmp/tb-clean sits on it, and the launch self-tests
   report PASS. Only if the ledger shows nothing did the hook miss — then run
   relaunch.sh yourself, with a note.
   Mechanics that still hold: merging is not deploying (a merged microphone
   fix once sat unrunning while the microphone kept failing, 07 Aug); the
   script is the only relaunch path — resolves against origin/main, refuses a
   dirty worktree, stops the old instance (two instances race for one global
   hotkey), gates on the launch self-tests.
   **Every deploy is on the record.** relaunch.sh writes `logs/deploys.log` at
   lock-take (invoker, ppid, session id when exported) and at ref-resolve —
   the ledger is the script's fact where the old announcement was a session's
   promise; attributing a deploy is a grep, not pid forensics. Announcements
   to other sessions remain the courtesy for anything UNUSUAL — a branch
   build, a manual deploy, a rollback — because a relaunch REPLACES whatever
   build is live, including a branch build mid-acceptance (earned 12 Aug:
   7bb2fe1 silently swapped out the ⌃⌃-fix build minutes before its dogfooding
   session; only a deploy note caught it).
   **One deployer runs at a time**, enforced by relaunch.sh's lockfile: a
   second concurrent run is refused outright, never interleaved. Earned 13 Aug
   at 05:06: two relaunches raced, one script's app_stop killed the other's
   freshly-drilled instance, and the restore trap resurrected the app bare,
   with no drills — the correct build running unverified behind a
   green-looking log, quieter and therefore worse than a loud collision.
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
