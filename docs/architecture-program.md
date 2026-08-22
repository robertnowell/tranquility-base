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

0. **Every milestone ends with an audit gate** (ruled 20 Aug: "between every
   stage of this build, deploy coding agents... is it cleaner than before?
   Are we duplicating or creating mess? Are we creating bug surfaces?").
   The gate = /code-review at high effort over the milestone's diff, plus an
   architecture-coherence agent for milestone-scale changes; findings are
   fixed or explicitly waived in the milestone's closing commit before the
   next milestone starts. Decision-blockers go to Robert immediately;
   everything else lands in the milestone note for later review.

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
  Terminal-naming user strings, the window-per-agent launch path and its
  ruling doc block (rewritten as history). `AgentDefaults.useTmux` and
  `launchTerminal` are DONE, ahead of the rest of this cut (ruled 21 Aug: "no
  feature flags... tmux is on" — a launch is tmux, unconditionally, full
  stop; no opt-in ever existed to remove by the time Codex is proven).
- **Hand-started sessions are adopted, never read-only** (ruled 20 Aug,
  reversing the read-only-rows trade: "announced but not voice-repliable is
  not acceptable... it should just work"). Every session on the machine
  appears in the grid from its transcript, whatever terminal it was started
  in — unchanged, and load-bearing for first-run users.
  **Corrected 21 Aug** (2026-08-21-tb-dual-live-harness-parity,
  2026-08-21-tb-codex-tmux-prior-art): the mechanism branches by harness, it
  is not one universal graceful-end. **Claude Code**: dual-live is measured
  safe, live, twice (first the raw experiment, then again through the real
  M3 dispatch path, 846dcbd) — Claude Code tolerates two processes on one
  conversation and arbitrates it with its own "Remote Control" feature. TB
  launches a tmux twin via `claude --resume <id>` and dispatches to it,
  **the user's original terminal untouched and left running** — no SIGTERM,
  no adoption in the graceful-end sense, just a second live process TB owns.
  `Coordinator`'s `preferringTmuxOwned` (846dcbd) is what makes replies land
  in TB's twin deterministically rather than an arbitrary one of the two.
  **Codex**: cannot dual-live — `codex-rs/app-server/README.md` states the
  single-writer lock directly ("only one app-server process can hold a
  paginated thread open for writing at a time... `thread/resume` fails with
  JSON-RPC `-32600`"), a second Codex process was measured live hitting
  exactly that error, and OpenAI was asked for the exact alternative
  (`codex inject`, issue #11415) and closed it "not planned." So Codex keeps
  the original design: graceful end (the existing clean SIGTERM path,
  "resumable via revive"), THEN `codex resume <id>` in a fresh tb- tmux
  session, then the closed-loop delivery — with the user's explicit approval
  on first attempted reply to a hand-started Codex session, never automatic.
  Both: the resume-depth dialog, when Claude Code shows one, surfaces
  through the dialog gate (a usage spend stays a human choice; one tap, then
  the reply flows). Replies to dead sessions revive straight into tmux.
  This is `allowsConcurrentResume` on `HarnessCapabilities` (not yet added —
  lands with CodexAdapter, since a capability with one harness to compare
  against is a field with no real question to answer).
- **GO TO AGENT = attach**: opens a terminal window running
  `tmux attach -t <session>`; detach leaves the agent running. Revive = tmux.
  The frontmost-suppression check generalizes to the active tmux client, or
  dies if it cannot be done cleanly (announce-always is the safe direction).
  **NOT YET BUILT, and currently a regression, not a pending enhancement**
  (codebase audit, 21 Aug): `SessionLauncher.focus(pid:)` walks Terminal.app
  tabs by tty; since every launch became tmux (cc7bf4e) that walk always
  misses, so the grid/past-agents "Go to agent" is a silent no-op for every
  session TB launches. `TerminalTabFocus` (the card's own door,
  `StatusHUD.swift:7132`) is the better-built implementation but is the same
  Terminal.app-tab mechanism underneath, so it is not a working fallback for
  a tmux-hosted session either. Fix direction: delete `SessionLauncher.focus`
  outright, route both call sites through one door, and give that door the
  `tmux attach` branch this bullet already describes as the design.
- **HarnessAdapter with two real implementations, no optional stubs:**
  ClaudeCodeAdapter and CodexAdapter land together, both load-bearing.
  Capabilities (liveSessions?, hooks?, echoesPaste, queuesInputMidTurn,
  promptGlyph, resumeArguments(), trustPromptSpec?, and
  `allowsConcurrentResume` — named 21 Aug, see the adoption bullet above)
  describe harness facts.
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

- [x] C0 Codex live battery (19-20 Aug). Delivery mechanics ALL HOLD on the
      real TUI: trust needle ("Do you trust the contents of this directory?",
      Enter accepts), composer echoes paste (glyph "›"), Enter submits,
      byte-exact user records in the rollout, task_started/complete pairs,
      3/3 clean unique deliveries under copy-mode churn. New needle found:
      the hooks-review dialog ("Hooks need review... Trust all and continue")
      — the launcher watcher must handle it, and hook-trust is the USER's
      choice, never auto-accepted. Discovery: Codex loads Claude plugins
      (~/.codex/plugins/cache/claude-plugins-official/...), so hook/skill
      surfaces are converging across harnesses — re-map on the current Codex
      before the adapter freezes capability values. Model-reply leg blocked
      by an account entitlement, not transport: config.toml pins gpt-5.6-sol,
      unsupported on ChatGPT-account auth (400) — flagged to Robert.
- [x] M1 (e090c92, gate e486743): Subprocess runner + per-element decode +
      readiness classify dedupe.
- [x] M2 (c8a837e, gate 99d81d8): HarnessAdapter + ClaudeCodeAdapter
      (launch, trust spec, capabilities); resume flag stops being written
      twice. Transcript-parser collapse (five parsers → one) NOT done —
      still open, folds into CodexAdapter below.
- [x] M3 (846dcbd): dispatch resolves the tmux-owned row deterministically
      when a session is dual-live, instead of an arbitrary `.first(where:)`
      pick — 4 real call sites (Coordinator + 3 transport-layer readiness
      probes) plus a 5th the gate caught (`tbase send`). Scoped to the
      tmux-owned half only; see the waiver in `preferringTmuxOwned`'s doc
      comment.
- [x] `AgentDefaults.useTmux` + `launchTerminal` deleted (ruled 21 Aug, "no
      feature flags... tmux is on"). Pulled forward out of the single-
      transport cut below — see "The end state" note above. `resume()`
      (revive) still opens Terminal.app; NOT yet decided whether that
      also moves now or waits for the full cut.
- [x] Audit gate, 21 Aug (self-reviewed, no external gate agent — noted, not
      hidden): a fresh no-priors sweep of Sources/ plus a doc/tracker
      reconciliation against git reality and all six research reports found
      and fixed: `tbase send`'s hand-derived transcript path (wrong for any
      session under `.claude/worktrees/`, i.e. every session working this
      arc — replies landed but could never confirm); an unbounded raw
      `Process` spawn on `SessionTermination`'s kill ladder (re-read before
      every rung; a wedged `ps` hung END SESSION with no trace) routed
      through `Subprocess.run`; a missing V4 dialog re-check on
      `TmuxTransport`'s OTHER Enter-press (could silently answer a
      resume-depth dialog — a real usage spend — under retry timing); a
      floor-check substring bug (`payload.contains(content)` could classify
      a human's half-typed message as TB's own and submit it); and
      `preferringTmuxOwned` discarding an already-resolved pane on its own
      "should not occur" fallback, forcing exactly the double-lookup its doc
      comment says the caller must avoid. Plus stale comments/strings across
      `SessionLauncher`, `AgentDefaults`, `Coordinator`, `HarnessAdapter`,
      `SessionTermination` still describing the deleted Terminal.app launch
      path as current. 739 tests, all green.
- [ ] CodexAdapter (load-bearing on landing: grid shows Codex sessions,
      dispatch delivers to them; rollout parser test-driven against the 177
      rollouts already on this machine); harness-conditional adoption
      capability + explicit ownership-handoff state machine land with it —
      see 2026-08-21-tb-codex-tmux-prior-art for why these three are one
      milestone, not `HarnessCapabilities` field first. Carries forward from
      that report and from C0 (19-20 Aug), concretely:
        - The `-32600` single-writer constraint (cited in the adoption bullet
          above) is what `allowsConcurrentResume` encodes; branch
          `Coordinator`'s adoption logic on it, don't re-derive it.
        - Launch-flag compensation, from AWS cli-agent-orchestrator's own
          Codex provider: force scrollback (Codex's approval UI breaks
          `capture-pane` otherwise) and a warm-up beat before first
          injection into a freshly spawned pane — Anthropic's own agent-teams
          hits the send-keys-before-shell-ready race in its own tracker,
          unresolved (claude-code #23513); Codex gets the same discipline
          from day one rather than discovering the race live.
        - Re-map the hook/skill surface on the CURRENT Codex before capability
          values freeze (C0 found it loads Claude plugins and runs
          SessionStart hooks — the "no hooks" parity read is stale) and give
          the hooks-review needle ("Hooks need review... Trust all and
          continue") its own `TrustPromptSpec` — hook-trust is the user's
          choice, never auto-accepted, and nothing enforces that today
          because no spec for it exists yet.
        - `thread/queue/add` requiring pre-existing writer ownership is a
          strong inference from the prior-art report, not verified against
          `codex-rs/app-server/src/` — cheap to confirm empirically before
          leaning on it.
- [ ] Single-transport cut, remainder: delete AppleScript dispatch machinery
      (TerminalAppTransport, the Automation permission gate); attach
      affordance in the panel (folds in the GO TO AGENT fix above); the
      useTmux/launchTerminal half of this is already done, above.
- [ ] Launcher: PATH/env from adapter; trust watcher unified; revive = tmux
- [ ] Coordinator split
- [ ] App lane P1-P10 (sequenced, drills green per step)
- [ ] Store riders + dead-code deletions: `TransportKind.iTerm2/.wezterm/
      .kitty` (never constructed; `Codable` + persisted, needs a decode-
      tolerance check, not a bare case removal), `Event.isHeadless` (`tty ==
      "??"`, zero callers — the tty discriminator open-issues.md #1 already
      calls dead; `SessionDiscovery.isHeadless(entrypoint:)` is the real,
      wired signal), `ProcessProbe.name(of:)` (zero callers).
- [ ] `SessionDiscovery.firstCwd` mis-homes a relocated session (found by
      2026-08-21-tb-division-of-labor: unfindable by project name, and
      `reviveCommand` would resume it in `~` rather than its real repo) —
      real defect, tracked in no doc until now.
- [ ] tmux server survival across a macOS logout/reboot — untested since the
      19 Aug validation battery, and now the highest-stakes gap on the board:
      after cc7bf4e tmux is the ONLY launch path, so a reboot that kills the
      server has no fallback. One manual test; launchd `KeepAlive` is the
      presumed fix if it's needed.
- [ ] Final: preflight, full drills, merge to main, deploy verified,
      freeze lifted
