# Architecture program — one arc, one merge, a beautiful machine

Ruled 19 Aug 2026, superseding the wave model ruled hours earlier (newest
ruling wins; Robert, verbatim intent): "We're not gonna do feature flags.
We're not gonna ship files that are not load-bearing. We're not gonna keep a
legacy path and a new path simultaneously. We're gonna commit and be
decisive... it's better if we rip out and throw away chunks of old
architecture that we don't need anymore. Because we want a beautiful machine."
The app is pre-launch; regressions on the way to the right architecture are
acceptable, flag rot is not.

The six-agent audit record behind every item:
`~/Documents/deep-research/2026-08-19-tb-architecture-program/report.md`.

## The rules of the arc

1. **One integration branch: `arc/beautiful-machine`, merged to main ONCE.**
   Intermediate commits on the arc may break features mid-branch; only the
   final merged state must be whole. Prod (the live app) never sees an
   intermediate state, because merges deploy and only the end merges.
2. **MAINLINE FREEZE while the arc is open.** Nothing merges to main
   underneath it except emergency fixes to the live app, which the arc
   rebases over immediately. Sessions wanting to help work ON the arc branch
   (worktrees off `arc/beautiful-machine`, PRs target the arc, one session in
   the app layer at a time still applies).
3. **No flags, no dormant files, no dual paths.** A capability on the
   HarnessAdapter describes a real difference between harnesses; a boolean
   that chooses between an old path and a new path is banned. If the new path
   is right, the old path is deleted in the same commit.
4. **The drills run on the arc continuously**, not only at the final deploy:
   `swift test`, `scripts/test-dispatch-tmux.sh`, and `--selftest-hud` against
   a branch build gate every arc-stacked PR. The final merge additionally
   passes preflight and the deploy self-tests like any other.
5. **The arc is short in calendar time.** Days, not weeks. The freeze is the
   forcing function; a stalled arc is the failure mode this rule watches for.
6. **Deletion is a feature.** Expected net-negative surfaces are listed below;
   an arc PR that only removes code is a good arc PR.

## The end state (what the merged arc contains, all load-bearing)

- **One dispatch transport: the tmux closed loop.** DELETED: the AppleScript
  injection walk, TerminalAppTransport, scripts/lib/canary-probe.applescript
  and canary.sh's Terminal path, the tab-walk in SessionLauncher.focus, the
  Automation (Terminal) permission and its onboarding gate, the four
  Terminal-naming user strings, `AgentDefaults.useTmux` (launches are tmux,
  full stop), the window-per-agent launch path and its ruling doc block
  (rewritten as history).
- **Hand-started sessions in plain terminal tabs become read-only rows**:
  announced (hooks and transcripts are transport-independent) but not
  dispatchable; the card says so and offers the fix ("start agents from the
  panel or tbase; they live in tmux"). This is the decisive trade: no
  AppleScript kept alive for the old habit.
- **GO TO AGENT = attach**: opens a terminal window running
  `tmux attach -t <session>`; detach leaves the agent running. Revive = tmux.
  The frontmost-suppression check generalizes to the active tmux client, or
  dies if it cannot be done cleanly (announce-always is the safe direction).
- **HarnessAdapter with two real implementations, no optional stubs:**
  ClaudeCodeAdapter and CodexAdapter land together, both load-bearing.
  Capabilities (liveSessions?, hooks?, echoesPaste, queuesInputMidTurn,
  promptGlyph, resumeArguments(), trustPromptSpec?) describe harness facts.
  The five hand-rolled transcript parsers collapse into the adapter's
  transcript store; the four status-vocabulary copies collapse into one
  normalized enum; the two trust watchers collapse into one loop over
  injected read()/press().
- **Codex gate (C0) runs FIRST, inside the arc's first days**: the live
  battery against a Codex TUI in tmux (echo check, two-step injection, busy
  queue, long payload, copy-mode ambush, exact-once churn). Its findings set
  the CodexAdapter's capability values. Codex rides the same tmux loop;
  app-server stays out (second transport = dual path).
- **Core correctness items land inside the arc** (A2 per-element decode, A3
  bounded Subprocess runner, A4 launch PATH from the adapter's candidate
  list, A5 attach affordance, A6 reapAudio, A7 speech lock, A8 firewall wired
  or deleted): each is part of the surface the arc rebuilds anyway.
- **Coordinator splits** (Announcer / ReplyPipeline / SessionSweep) and the
  **app-layer decomposition** (P1-P10 from the audit: dead code deleted, leaf
  views and drills out of StatusHUD, grid policy down to Core with unit
  tests, main.swift extensions, the async logger) — executed as arc-stacked
  PRs in the app lane, one session at a time.
- **Store riders**: one cache, one append-only log, one trace sink,
  PrivateStorage tests, fontSheetRoot out of ~/.claude.
- **Vestigial code from the audit's dead lists is deleted, not preserved**:
  SpeakTier, dormant hail, PlacardRowView/PaneLinkRowView, write-only state,
  TransportKind.iTerm2/.wezterm/.kitty (YAGNI; tmux is the transport),
  the no-op clearOldNotifications, tools/replay one-off JSONs.

## Untouched, by standing ruling

The sdk-cli exclusion (robots stay out of the grid), typing fails closed, the
dialog gate, the one-Return retry, the delivery watermark, bundle id
com.robertnowell.voice-dispatch (TCC).

## Already landed on main before the freeze

- [x] Program doc (PR #166), delivery watermark A1/A10/B2 (PR #167,
      deployed b20d0fa), tmux transport + kind decode (PR #164).

## Arc checklist (ticked by arc-stacked PRs; order is a guide, not a gate)

- [ ] C0 Codex live battery; record capability values in the adapter
- [ ] Subprocess runner + per-element decode + readiness classify dedupe
- [ ] HarnessAdapter + ClaudeCodeAdapter (liveness, transcripts, launch,
      hooks, trust spec); five parsers collapse
- [ ] CodexAdapter (load-bearing on landing: grid shows Codex sessions,
      dispatch delivers to them)
- [ ] Single-transport cut: delete AppleScript dispatch machinery, Automation
      permission gate, useTmux flag; launches are tmux; attach affordance in
      the panel; read-only rows for plain-terminal sessions
- [ ] Launcher: PATH/env from adapter; trust watcher unified; revive = tmux
- [ ] Coordinator split
- [ ] App lane P1-P10 (sequenced, drills green per step)
- [ ] Store riders + dead-code deletions
- [ ] Final: preflight, full drills, merge to main, deploy verified,
      freeze lifted
