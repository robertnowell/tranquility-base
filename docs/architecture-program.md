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
  (`codex inject`, issue #11415) and closed it "not planned."
  **Superseded 22 Aug** (2026-08-22-tb-codex-hand-started-adoption, revised
  twice same day): the original design here was TB-initiated graceful end
  (SIGTERM the foreground process, with the user's approval) THEN
  `codex resume <id>`. That needed knowing WHICH process to end — the exact
  problem `CodexProcesses` was built and then deleted over (see the
  CodexAdapter checklist item below). Settled instead: TB never ends a
  Codex process itself, ever. It attempts `codex resume <id>` directly;
  success means the session wasn't live and TB now owns it; the measured
  `-32600` failure IS the "it's live elsewhere" signal, authoritatively,
  with zero side effects either way — TB asks the human to end it in their
  own terminal, then retries. This also means Codex needs no adoption
  approval prompt the way the line above once implied: there is nothing to
  approve, only a resume that either works or doesn't.
  Both harnesses: the resume-depth dialog, when Claude Code shows one,
  surfaces through the dialog gate (a usage spend stays a human choice; one
  tap, then the reply flows). Replies to dead sessions revive straight into
  tmux. This is `allowsConcurrentResume` on `HarnessCapabilities` — true for
  Claude Code (always resume a twin), false for Codex (attempt-and-read the
  answer, above).
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
- [~] CodexAdapter — in progress. Landed (21 Aug, two commits — the second a
      gate-driven correction, not a formality: the gate independently
      re-measured live against a fresh Codex process rather than just
      reading the diff, and found a real bug plus a wrong claim in the
      first):
        - [x] `CodexAdapter: HarnessAdapter`, every value measured live
          against codex-cli 0.149.0 in a real tmux pane, not carried forward
          from 19-20 Aug guesses: `resumeArguments` = `["resume", id]`;
          `echoesPaste`/`promptGlyph` ("›") confirmed on the composer;
          `queuesInputMidTurn` confirmed by actually sending two messages
          back to back (plain Enter mid-turn queued the second, answered as
          its own turn — the SAME mechanism TB's transport already uses, no
          new one needed); `hasHooks` reconfirmed by two real SessionStart
          firings (re-map done, not just cited from C0); `registersWithLiveness
          = false`. `allowsConcurrentResume = false` is 19-20 Aug + repeated
          this session, not new today. **`settledBannerNeedle` corrected by
          the gate**: shipped as "OpenAI Codex" (the header box), independently
          re-verified live and found to scroll into scrollback within ~1s of
          any real output — invisible to the plain `capture-pane -p` read
          `SessionLauncher` actually does, which would have burned the
          watcher's full ~30s timeout on every ordinary Codex launch. Now
          "Ask Codex to do anything", the composer's own idle placeholder,
          confirmed 10/10 across repeated polls because it sits at the
          bottom of the pane, not in scrollable history.
        - [x] `HarnessCapabilities.allowsConcurrentResume` named and wired on
          both adapters (true / Claude Code, false / Codex) — the field this
          item used to say would land here, done.
        - [x] The hooks-review needle ("Hooks need review... Trust all and
          continue") has its own home: `TrustPromptSpec.neverAutoAcceptNeedles`,
          a new watcher primitive that stops rather than presses — checked
          before `promptNeedles`, verified (by the gate, reading the control
          flow directly) to never press on a screen matching both lists.
          NOT reconfirmed live today (this scratch dir had no project-level
          hook config to retrigger it) — carried from C0. Honestly scoped,
          not "true by construction" alone: no call site passes `CodexAdapter`
          into `SessionLauncher.watchForTrustPrompt` yet, so the guarantee
          lives in the type, not in anything that runs; and even once wired,
          Codex loads hooks only AFTER directory trust is granted, so a
          first-run untrusted launch presses trust and returns before a
          hooks-review dialog could render — this fires on an already-
          trusted launch whose hooks changed since the last review, not the
          common first-run case.
        - [x] `CodexRollout.swift`: parses `session_meta`, `task_started`/
          `task_complete`/`task_aborted` (busy/idle + `last_agent_message` —
          no `response_item` scanning needed for "what did it just say"),
          `response_item` messages (filtering Codex's own injected
          `<environment_context>` wrapper — found live, not anticipated —
          out of user-role messages at ANY position in a turn, plus
          `developer`-role and `agent_message`-type records, all confirmed
          by sampling real occurrences to be injected system context or
          inter-agent routing, never anything a human or TB typed), tolerates
          `compacted`/`world_state`/`turn_context`/`inter_agent_communication_metadata`.
          `rolloutPath(forSessionId:)` finds a thread's file by the filename
          Codex itself writes, no directory-layout guessing. `skippedLines`
          on `Parsed` makes an undecodable line visible instead of silently
          absent — this file's own doc block already cited the "one bad row
          nilling an entire probe" lesson; the gate found the inverse gap
          (a bad row disappearing with no signal at all) wasn't closed yet.
          **`turn_aborted` was unhandled at first landing — a real bug, not
          a nitpick**: the gate measured that alone made 55/192 real
          rollouts on this machine (29%) read as falsely busy, 13 of them
          purely from an unhandled abort. Fixed; `isBusy`'s own doc comment
          now says plainly what it still can't do — distinguish "still
          working" from "killed mid-turn with no cleanup event at all"
          (42/192 on this machine), which needs `processAlive` or rollout
          mtime at the wiring call site, not in this pure parser.
          Fixture-tested (portable, matching this repo's own convention:
          every fixture that matters — the wrapper at a non-first position,
          content that only starts like the wrapper but isn't, the abort
          case, the orphaned-completion case, an `id`/`session_id` mismatch
          — traces to something the 192-real-file sweep or the gate's
          re-reading actually found, not invention) AND run against all 192
          real rollouts on this machine (six Codex versions, 0.133.0-alpha.1
          → 0.149.0) as a one-time sanity pass. That sweep is honestly
          qualified now: meta/messages/completions extracted cleanly on
          192/192, but `isBusy` was the one field it didn't check — the
          exact field the `turn_aborted` bug lived in, until the gate reran
          the numbers.
      **`promptGlyph` half landed (4354d8d, 21 Aug)**: `DispatchTarget` now
      carries its own harness's floor-check glyph (default `❯`, so every
      existing site is unchanged); `TmuxTransport.classifyPromptLine` reads
      it instead of the `❯` literal. Closes the specific hazard where a
      Codex pane (echoes behind `›`) would have read as permanently `.empty`
      on the floor check and silently skipped the never-splice-into-
      unsent-text guard. Mechanism only, same shape as `resumeTmux`: no
      call site builds a non-Claude-Code target yet.
      **`readinessSource` half landed (b878125, 22 Aug)**: new
      `DispatchTarget.ReadinessSource.rolloutTail` case, and
      `Readiness.classify(rollout:)` mirroring the existing
      `classify(_:LiveSession?)` — no rollout found fails closed
      (`.notRegistered`), found-and-busy dispatches (`.busy`, Codex queues
      mid-turn same as Claude Code), found-and-idle is `.ready`. Both
      transports' pid-alive check already runs before `readinessSource` is
      consulted, which for free covers `CodexRollout.Parsed.isBusy`'s own
      documented gap (a process killed mid-turn is indistinguishable from
      one still working, from the rollout alone) — `.targetGone` fires
      first. Deliberately narrower than Claude Code's mapping: no
      Codex-specific dialog/waiting state exists in a rollout, so
      `TmuxTransport`'s V4 dialog re-probe stays scoped to `.claudeAgents`
      only — an honest "unverified" for Codex's mid-turn dialog risk, not a
      measured "safe". Mechanism only, same shape as the two before it: no
      call site constructs a `.rolloutTail` target yet.
      **`CodexProcesses` landed (395cedb, 22 Aug) then deleted (ef0600b, same
      day)** — a real pid-attribution primitive, built after spinning up a
      real Codex session to measure rather than assume, then found
      unnecessary within the same day once the adoption question it served
      was talked through properly. Worth recording the shape of the mistake
      honestly: it tried to answer "which process IS this session" from OS
      state (argv, cwd) before acting, and for a bare unresumed process
      sharing a directory with another one, that question has no reliable
      answer — confirmed by survey (2026-08-22-tb-codex-hand-started-adoption):
      claude-squad, vibe-kanban, and AWS's cli-agent-orchestrator all avoid
      it entirely, architecturally (one directory per session, always
      self-launched), rather than inferring it. The fix wasn't a better
      heuristic, it was asking a narrower question Codex's own protocol
      already answers for free — see the adoption design below, now settled.
      **Adoption design, settled (22 Aug, same two reports)**: TB never
      identifies a live Codex process before acting. It attempts
      `codex resume <id>` directly (`resumeTmux`, already built) and reads
      Codex's own answer:
        - Succeeds → the session was not actually live; TB now owns the pid
          with certainty, same footing as anything it launched itself.
        - Fails, `-32600` → the session IS live, somewhere TB doesn't
          control — measured live with zero side effects on either side
          (the attempt just exits, status 1; the original process and its
          rollout are untouched). TB reports "already running — end it in
          that terminal, then try again," citing the session's own
          directory/last-known content so the user can find the right tab.
      This closes the hand-started-adoption question completely, including
      the same-directory-collision case (two sessions, e.g. one on Mars, one
      on New Horizons): TB never needs to tell them apart, because it is
      always resuming ONE specific session id — the one the user picked
      from TB's own history — never guessing from a directory. Kill and
      quiet inherit this for free: both only ever apply to a pid TB
      currently holds, and TB only ever comes to hold a Codex pid through a
      resume that already succeeded, so there is no code path where either
      reaches an unverified process. **This also retires the
      ownership-handoff state machine** (observed → handoff-requested →
      releasing-writer → managed) **entirely, for both harnesses** — Claude
      Code never needed one (dual-live), and Codex's version of it
      (TB-initiated graceful-end, with the mid-keystroke SIGTERM gate that
      would have required) is superseded: TB never sends a Codex process it
      doesn't own any signal at all. The human ends it, in their own
      terminal, on their own judgment about their own unsaved keystrokes —
      strictly safer than TB inferring when it's safe to do so itself, and
      no state machine is needed to get there.
      Still open, concretely:
        - Wiring: `CodexRollout` into session discovery so the grid shows
          Codex history; a real call site building `.rolloutTail` /
          Codex-glyph `DispatchTarget`s once a resume succeeds; hooking the
          resume-attempt's `-32600` detection into the actual message shown
          (needs a specific check — the launched pane's process exiting
          within ~1-2s of spawn, screen text matching the known error
          string — not yet built, `resumeTmux` today just launches and
          returns a tty, it doesn't yet distinguish this failure mode from
          a successful launch).
        - Launch-flag compensation for Codex specifically (force scrollback,
          warm-up beat before first injection — AWS cli-agent-orchestrator's
          own Codex provider, and Anthropic's own unresolved send-keys race,
          claude-code #23513) — not yet in the launch path.
        - `thread/queue/add` — no longer relevant to the chosen design (it
          never engages `app-server`'s queue surface at all, only plain
          `codex resume`); the earlier note about verifying it against
          `codex-rs/app-server/src/` is moot, not merely stale.
      **`resumeTmux` landed (00b060d, 21 Aug)**: the one mechanism both
      adoption strategies bottom out in — build resume arguments through
      the adapter, spawn a fresh TB-owned detached tmux pane, watch that
      harness's trust prompt — factored out of `launchTmux` rather than
      duplicated. `launch`/`launchTmux` now take the adapter as a real
      parameter instead of `launchTmux` silently defaulting to
      `ClaudeCodeAdapter()` regardless of what was being launched (latent
      since nothing called it with Codex yet). Refuses loudly on empty
      `resumeArguments`, mirroring `resume()`'s existing guard. This is
      mechanism only — no policy, no call site yet, no ownership-handoff
      state machine above it; the three "still open" items above are
      unchanged by this. 772 tests, both drills green.
- [x] Second audit gate, 21 Aug (two fresh agents, no priors: a codebase
      drift/smell sweep of everything since 686f11a, and a docs/tracker
      reconciliation against the ORIGINAL 19 Aug architecture brief). Clean:
      no new adapter-abstraction bypass, no new dictionary-trap risk (the
      1eefac5 fix pattern held; CodexRollout doesn't reintroduce it — its
      `openTurns` is a `Set`, insert/remove on a duplicate is a correct
      no-op, not a trap), no self-inconsistency in the last four commits,
      every `[x]` checklist item traces to a real matching commit. Two real
      findings, both folded in rather than just noted: the mid-keystroke
      SIGTERM gate above, and open-issues.md #27 (a duplicate
      `case "settings":` in `StatusHUD.swift`'s pose-fixture switch, named in
      the ORIGINAL brief's Track A item 9 and then dropped from every doc
      for two days until this pass re-found it — cosmetic today, but the
      kind of drift this gate exists to catch). One theoretical, declined
      finding: `CodexRollout.rolloutPath(forSessionId:)` takes the first
      filename match on a thread-id suffix with no duplicate check —
      speculative given Codex thread ids are UUIDs, not actioned.
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
