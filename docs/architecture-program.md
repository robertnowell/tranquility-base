# Architecture program — one arc, one merge, a beautiful machine

**v2, 23 Aug 2026.** Supersedes `architecture-program-v1.md`, kept in place
rather than deleted — the record below is preserved almost entirely; v2
exists because one section of v1 (dual-live, marked below) was found to
describe the OPPOSITE of what shipped later the same day, and a doc that
actively contradicts the running code is worse than a stale one. See
`~/Documents/deep-research/2026-08-23-agent-session-transport/` (the
transport report) and `~/Documents/deep-research/2026-08-23-tb-architecture-
checkpoint/` (the audit that triggered this rewrite) for the evidence.

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
  **Corrected 21 Aug, then reversed 23 Aug — this is the section v1 got
  wrong; read this version, not that one.** The 21 Aug correction
  (2026-08-21-tb-dual-live-harness-parity, 2026-08-21-tb-codex-tmux-
  prior-art) said the mechanism branches by harness: Claude Code
  dual-lives (a tmux twin resumed alongside the hand-started process, left
  running, unsignalled — "the user's original process never signalled and
  left running... ruled acceptable, the bar is dispatch WORKS, not which
  pane a human happens to see it land in"), Codex cannot (single-writer
  lock). **The Claude Code half of that ruling is retired, on a measurement,
  not an argument** (CLAUDE.md rule 4's own bar): the "dual-live is safe"
  premise assumed Claude Code's Remote Control would keep a hand-started
  session's own terminal in sync with whatever the tmux twin was doing.
  It doesn't, in the shape TB needs it to — live-caught 23 Aug on this very
  session (sessionId `f37aaddd`): once dispatch started answering the twin,
  nothing was watching the hand-started terminal any more, so every reply
  after the first routed to a pane the human had no way to see. Confirmed
  via `ps`: the twin's parent was TB's own `tmux new-session`; the original,
  a bare interactive `zsh`, sat there stale.
  **No parallel human+tmux session, ever, for either harness — ruled 23 Aug,
  blunt: "when human session exists, interacting with session — i.e.
  clicking it or bringing it forward — ends human session and creates tmux
  session — it must always work, it cannot work only sometimes... tmux owns
  when TB used to interact with session."** `SessionLauncher.
  OwnershipTransfer.toTmux(sessionId:directory:)` is the one mechanism:
  ends the hand-started process (`SessionTermination.end`, the same clean-
  SIGTERM path `tbase end` already used), confirms it is actually gone —
  positive evidence of death, `resumeTmux`'s own existing requirement — THEN
  resumes fresh under tmux. `Coordinator.dispatch`'s `resumeTwin` and
  StatusHUD's `goToSession()` both call it: typing into a hand-started
  session transfers it, and so does bringing it forward, not just the
  first one. `preferringTmuxOwned` (846dcbd) still exists and still matters
  for the brief window between a transfer starting and the old dedup
  catching up, but it is no longer arbitrating a PERMANENT dual-live state —
  there is no such state any more, for either harness. Live-validated
  end-to-end, twice (once for the dispatch-triggered transfer, once for the
  Go-to-Agent-triggered one): a real Terminal.app session given one real
  turn, transferred, confirmed via `claude agents --json` down to exactly
  one live entry afterward, with the prior turn intact in the new pane.
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
  tap, then the reply flows).
  **Corrected 23 Aug (aa980a3)**: "surfaces through the dialog gate" was true
  of the DECISION (nothing auto-presses it, still true) but not of the
  VISIBILITY — found live when a revive landed on this exact dialog and
  showed a green success chip with no way to see the question at all. Fixed:
  `TrustPromptWatcher`'s `onNeedsHuman` now opens a Terminal window on the
  pane automatically the moment a never-auto-accept needle is hit (this
  dialog, and Codex's hooks-review dialog, for free) — no click required,
  matching what AppleScript's `activate` used to do for this exact case
  before revive moved onto resumeTmux.
  Replies to dead sessions revive straight into
  tmux. This is `allowsConcurrentResume` on `HarnessCapabilities` — true for
  Claude Code (always resume a twin), false for Codex (attempt-and-read the
  answer, above).
- **GO TO AGENT = attach, or transfer.** `TerminalTabFocus.focus(tty:)` tries
  `TmuxOwnership.pane(forTty:)` first; when it resolves, `list-clients` is
  checked too (23 Aug fix, below) and an ALREADY-attached window is raised
  rather than mirroring a second one in. When it does NOT resolve — a
  hand-started session — the 22 Aug design (Terminal.app tab walk, unchanged
  fallback) is superseded by the no-parallel-session ruling above: clicking
  Go to Agent on a hand-started session now calls the same
  `OwnershipTransfer.toTmux` dispatch uses, then attaches the new pane.
  Bringing a session forward is an interaction with it, same as typing into
  it, so it gets the same treatment. The Terminal.app tab walk in
  `TerminalTabFocus.script(focusing:)` is kept as code (still the correct
  answer for the narrow case a transfer itself fails) but is no longer the
  steady-state path for any hand-started session a human actually clicks on.
  **Fixed (3a641d2, 22 Aug)** — caught live by Robert clicking it, not by any
  gate: reproduced immediately on a session launched seconds earlier, so this
  was never one stale row, it was universal since `cc7bf4e`. Neither
  `swift test` nor `--selftest-hud` cover this path (a real AppleScript/
  Terminal.app interaction, and no click-through drill exists for the
  button specifically), which is the honest reason it sat on this checklist,
  correctly labeled a regression, until it was actually clicked.
  `SessionLauncher.focus(pid:)`, the other copy of the same broken walk,
  deleted outright; its one call site now routes through the same door the
  card already used. Live-verified against the exact session from the bug
  report: hand-built the identical AppleScript, ran it, and
  `tmux list-clients` confirmed a real client attached.
  **The frontmost-suppression check generalizing to the active tmux client —
  closed 23 Aug**, the same day it was flagged: tmux mirrors a second client
  onto a session with one already attached, which is exactly how clicking
  Go to Agent twice opened two Terminal windows onto the same pane
  (confirmed live: two real sessions each sitting with two attached clients
  apiece before the fix). `focus(tty:)` now checks `list-clients` before
  attaching and raises the existing window instead.
- **HarnessAdapter with two real implementations, no optional stubs:**
  ClaudeCodeAdapter and CodexAdapter land together, both load-bearing.
  Capabilities (liveSessions?, hooks?, echoesPaste, queuesInputMidTurn,
  promptGlyph, resumeArguments(), trustPromptSpec?, and
  `allowsConcurrentResume` — named 21 Aug, see the adoption bullet above)
  describe harness facts.
  **The axis is the harness, not the terminal — confirmed 23 Aug**
  (2026-08-23-agent-session-transport report, finding #1). Deleting
  `TransportKind.iTerm2`/`.wezterm`/`.kitty` (below) is right — YAGNI, tmux
  is the transport — but the report's sharper point is what the enum WORTH
  keeping would describe if TB ever needed it: not which terminal emulator
  runs a pane, but how TB talks to the agent at all — tmux-TTY (today, the
  only one built), SDK-headless, Codex app-server. `HarnessAdapter` already
  names itself correctly by this axis; this is the doc catching up to what
  the code already got right, not a rename.
  The five hand-rolled transcript parsers collapse into the adapter's
  transcript store; the four status-vocabulary copies collapse into one
  normalized enum; the two trust watchers collapse into one loop over
  injected read()/press().
- **Codex gate (C0) runs FIRST, inside the arc's first days**: the live
  battery against a Codex TUI in tmux (echo check, two-step injection, busy
  queue, long payload, copy-mode ambush, exact-once churn). Its findings set
  the CodexAdapter's capability values. Codex rides the same tmux loop;
  app-server stays out (second transport = dual path).
- **ACP (Agent Client Protocol): considered, not adopted — closed 23 Aug**
  (2026-08-23-agent-session-transport report, finding #3). No first-party
  Codex adapter (openai/codex#2785, open since Aug 2025, no maintainer
  response — only a community bridge tracking Codex's own moving protocol
  from outside); the Claude adapter wraps the Agent SDK anyway, so ACP would
  be indirection over a call TB can make directly; no supervisor precedent
  among its confirmed clients (Zed, two Neovim plugins, Emacs, marimo, VS
  Code — all editor plugins or terminal UIs). One idea kept without the
  dependency: ACP's own split between `session/request_permission` (a
  security decision) and `elicitation/create` (a free-text question) is the
  same distinction `WaitingAt`'s `.permission`/`.question` split landed on
  independently, from the opposite direction — reached again the same day,
  the two agreeing is itself the evidence the modeling is right.
- **Core correctness items land inside the arc** (A2 per-element decode, A3
  bounded Subprocess runner, A4 launch PATH from the adapter's candidate
  list, A5 attach affordance, A6 reapAudio, A7 speech lock, A8 firewall wired
  or deleted): each is part of the surface the arc rebuilds anyway.
- **Coordinator splits** (Announcer / ReplyPipeline / SessionSweep) and the
  **app-layer decomposition** (P1-9 from the original audit report
  [2026-08-19-tb-architecture-program]: 1 dead code + pose fix, 2 Widgets
  struct + TestSurface, 3 leaf views out (~1,640 lines), 4 drills+pose out
  (~3,200), 5 receipt/build/geometry extensions (core lands ~2,500), 6
  SessionRow model + grid statics to Core with unit tests, 7 main.swift
  extension split, 8 GridAssembler to Core, 9 Recorder/CaptureUnit/log-writer
  to Core) — executed as arc-stacked PRs in the app lane, one session at a
  time. **Two of the report's "transport conditionality" riders under this
  item are already satisfied, ground-checked 23 Aug**, not by an App-lane PR
  but as a side effect of the single-transport cut above: the four
  Terminal-naming user strings are gone with `Permissions.Kind.automation`
  (4eaf17f), and `goToSession` already routes through the injected
  `onGoToSession` callback (StatusHUD.swift:2529), not a direct transport
  call — nothing left to do for either rider when P1-9 starts.
- **Store riders**: one cache, one append-only log, one trace sink,
  PrivateStorage tests, fontSheetRoot out of ~/.claude.
- **Vestigial code from the audit's dead lists is deleted, not preserved**:
  SpeakTier, dormant hail, PlacardRowView/PaneLinkRowView, write-only state,
  ~~TransportKind.iTerm2/.wezterm/.kitty~~ (YAGNI; tmux is the transport —
  **done, ff98d7f, 23 Aug**), the no-op clearOldNotifications, tools/replay
  one-off JSONs.
- **The grid draws idle before dead, not dead before idle — reversed 23 Aug**
  on a fresh screenshot: a dead test session (killed minutes earlier, on
  purpose) sat in a floor slot while a genuinely live, idle session was
  bumped to the list instead. The 18 Aug ruling behind this ("the grid is
  for lit lamps") had already flagged this exact question as unresolved in
  its own doc comment — "dead rows still sort last and still only reach the
  grid when the floor has slots going spare; if that is also wrong it is a
  separate ruling, with its own drills." It was. `gridRows` now fills its
  slot budget lit-first, then alive-but-quiet, then dead last.

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
      **`attemptCodexResume` landed (db29620, 22 Aug)** — the detection this
      item used to describe as not-yet-built. `SessionLauncher.
      attemptCodexResume` tries `codex resume <id>` and returns
      `.attached`/`.alreadyLive`, whichever Codex's own server actually
      says. Two real bugs found only by running it against a genuinely live
      conflicting session (twice), not by reasoning: (1) the first version
      launched `claude resume <id>` by accident — `resumeTmux`'s `command`
      defaults to the Claude-Code-specific `AgentDefaults.load()`, now
      passed explicitly as `"codex"`; (2) a losing resume does NOT keep its
      error on screen for several seconds — timed precisely at under a
      second, twice — correcting a WRONG mid-conversation claim to the
      contrary that had itself come from a measuring script's own trailing
      `sleep` propping a dead pane open, not real Codex behavior. Rebuilt
      around the reliable signal (pane survival through a short grace
      window) with screen-text matching kept as a bonus, not the mechanism.
      Live-verified end to end, both outcomes, via a temporary real-machine
      smoke test (deleted after passing, per convention). Mechanism only:
      no call site wires this into a real dispatch/discovery flow yet.
      **`discoverCodex` landed (d95d9f9, 22 Aug)** — session history off
      disk, Core-only, roadmap step 1 (2026-08-22-tb-codex-verified-and-
      roadmap). `SessionDiscovery.discoverCodex` walks `~/.codex/sessions`
      and produces the same `Session` rows Claude Code's own `scan` does;
      `Session` gained a `harness` field (defaulted everywhere, nothing
      else needed to change) and `reviveCommand` now does the per-row
      adapter lookup its own doc comment had anticipated since M2. Liveness
      is never guessed — every row reads `.unknown`; `revivable` follows
      the launch directory existing, not `liveness == .gone`, since
      attempting a resume is always safe to try. Verified against this
      machine's real `~/.codex/sessions` (19/19 real files scanned and
      correctly classified) via a temporary smoke test, deleted after
      passing. Honest gaps carried forward, not hidden: no title mechanism
      for Codex yet, no `SessionActivity`-equivalent classifier, no
      per-message timestamp in `CodexRollout`'s parsed shape (file mtime
      stands in for all three).
      **`tbase discover`/`revive` went multi-harness (bbccfef, 22 Aug)** —
      the roadmap's "real call site" step, landed narrower than originally
      scoped and on purpose. Original step 2 said "the grid" — but
      `sessionRowsNow()` (`main.swift:1380+`) turned out to be dense,
      extensively-tuned, Claude-Code-specific precedence logic (lamp state,
      blocked-on-you, resumed-vs-working) with zero unit coverage (rule 7:
      StatusHUD has none), and merging a second data source into it with no
      established band/lamp semantics is a real app-layer design task, not
      something to rush riding a Codex push. `tbase discover`/`revive` call
      the SAME mechanism the panel's row already does (`SessionDiscovery`,
      `SessionLauncher`) with none of the panel's risk — landed there
      instead, live-verified end to end against a real Codex session (both
      outcomes: attach, and refuse-because-already-live).
      Also surfaced, only by actually scoping this: voice-dispatch into an
      already-attached Codex session, and kill/quiet, both need TB to
      remember which pid it currently holds for a session id.
      **Corrected same day (2026-08-22-tb-codex-remaining-design, then
      Robert directly): the grid-integration caution above overshot, and
      the ownership record was scoped too narrowly.**
      **`SessionOwnershipStore` landed (bac6855, 22 Aug)** — general by
      design, not `CodexOwnership`: a protocol (`record`/`current`/
      `remove`/`all`, plus `verifiedCurrent` as a liveness-gated extension
      any conformance gets for free), the same posture `ClaudeAgentsReading`
      and `DispatchTransport` already take, so a future hosted backend is a
      second conformance, not a rewrite. `FileSessionOwnershipStore` is
      today's only one — one JSON file, `AgentDefaults`'s own shape. Codex
      is the only writer today because nothing reads this for Claude Code
      yet (`agents --json` still answers everything Claude Code's own paths
      ask) — stated as a scope call, not silently narrower than it looks.
      Solving this needed one more real primitive: `ProcessProbe.
      pid(onTty:containing:)` finds the actual agent pid inside a tmux pane
      (not tmux's own `#{pane_pid}`) by matching the session id in argv —
      measured live that zsh's own last-command exec optimization replaces
      the wrapping shell even inside `launchTmux`'s `cd X && command args`,
      and that a resumed Codex process can spawn its own children (MCP
      servers) on the same tty, so a name-prefix match alone could not tell
      parent from child. `attemptCodexResume`'s `.attached` path now records
      ownership on every successful attach — live-verified against a real
      session, recorded pid confirmed against `ps` to be the genuine
      `codex resume <id>` process.
      **The grid itself landed too (eae2f9c, 22 Aug)** — re-reading
      `sessionRowsNow()` (prompted by being told this should not have been
      presented as a decision) found the caution above was wrong: Codex
      rows never needed the dense waiting/lamp precedence logic at all,
      only the already-generic closed-band loop, which took every field a
      Codex row has (nil title, nil activity, a real `revivable` bool)
      without modification. New `discoverCodexIfScanned`/`warmCodex`
      (a second `ScanCache` instance, not a second implementation) so the
      per-refresh cost — measured close to a second against 19 real
      rollouts — never runs on the panel's own thread. `revive(sessionId:
      name:)` in the app itself is now harness-aware too, mirroring `tbase
      revive`'s already-proved branch.
      **`tbase send`/`end` reach Codex (d6694d1, 22 Aug)** — the mechanism
      the ownership record was built toward. Getting there live found three
      real bugs, all found by actually dispatching to and ending a genuine
      codex-cli 0.149.0 session, none reasoned in advance: (1) the floor
      check read Codex's own idle-composer hint text as a human's unsent
      message (`capture-pane -p` carries no color to tell them apart),
      refusing every dispatch to an idle session — fixed with
      `DispatchTarget.idlePlaceholder`; (2) `TranscriptWatcher`'s dedup and
      landing-verification only ever parsed Claude Code's transcript shape,
      which a Codex rollout never has, so both silently failed for Codex and
      a retry actually double-pasted a payload into a live session (caught
      live, "PONG" landed twice) — fixed with `codexUserMessages`/
      `waitForCodexUserText`, read through `CodexRollout.parse`; (3)
      `SessionTermination`'s pid-reuse identity guard was hardcoded to
      Claude Code and refused to end a real, ownership-verified Codex
      process ("pid 71800 is `codex`, not a Claude session") — generalized
      to an `expectedCommand` parameter (default `"claude"`, every
      pre-existing caller unchanged) rather than bypassed, since the guard
      itself is the safety property. `HarnessAdapter` gained
      `processCommandFragment`, deliberately distinct from `id` (Claude
      Code's id is `"claude-code"`, its binary is `claude`) so a future
      harness can't silently reintroduce the same mismatch. Live-verified
      end to end: `tbase end 01a02b5f` on the exact session bug #3 was
      found on — died on SIGTERM in 261ms, pid confirmed gone, ownership
      record removed, tmux torn down with it. Production TB instance
      (single pid, confirmed) was never touched throughout — held off on
      any relaunch for Robert's demo.
      **`--selftest-hud` run against the panel (d9b9bd5 deployed, 22 Aug)** —
      the demo that was blocking this cleared, Robert cleared touching the
      running app, and `arc/beautiful-machine` went live via
      `scripts/relaunch.sh arc/beautiful-machine` (the sanctioned
      branch-build path, `main` untouched): 49/49 self-test verdicts passed,
      panel accepting input idle, canary green (Claude Code contract holds).
      One unrelated pre-existing finding surfaced by the deploy's
      `tbase doctor` gate: 3 content-engine hub pages (dated 19–21 Aug, not
      touched by this arc) carry duplicate agent footers — noted, not yet
      fixed, `tbase homebase <id>` is the documented one-line repair.
      **`scripts/test-codex-lifecycle.sh` landed (4302804, 22 Aug)** — the
      roadmap's last "still open" item. Seeds a real session via `codex exec`
      rather than a stand-in harness (attach needs a genuine
      `~/.codex/sessions` rollout and a real `codex resume`), then drives
      `tbase revive` → `enroll` → `send` → `end` and asserts each leg,
      cleaning up unconditionally on exit. Caught one more live bug getting
      there: plain `codex delete` silently no-ops without a tty (prompts for
      confirmation that never comes); `--force` fixed it, confirmed by
      checking the rollout file was actually gone afterward rather than
      trusting a zero exit code. 6/6, run twice.
      Still open, concretely:
        - The 3 duplicate-footer hub pages found by the `--selftest-hud`
          deploy's `tbase doctor` gate — unrelated to this arc, not yet
          repaired.
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
- [x] Single-transport cut, remainder (9d4ffd2, 4eaf17f — 23 Aug): deleted
      `TerminalAppTransport` (its `injectScript` helper, the `tbase send-raw`
      drill command, `scripts/test-dispatch.sh`) and the Automation
      permission gate (`Permissions.Kind.automation` and every switch arm,
      `automationStatus()`) outright, on the operator's own instruction
      (23 Aug: "I don't know why tmux would ever be not available... is
      there really a situation where tmux would not be available") — no
      fallback transport is preserved; `Coordinator.dispatch` and `tbase
      send` now refuse cleanly (`.injectionFailed`) when `resumeTwin` can't
      produce a pane, rather than silently rerouting through a
      far-less-tested mechanism. 834/834 tests green (9d4ffd2 deployed and
      canary-verified live; 4eaf17f — Permissions.swift only, app-layer —
      committed, deploy pending a live mic at commit time per the
      never-kill-a-capture rule, verify on the next relaunch). The attach
      affordance itself landed separately (3a641d2, 22 Aug, GO TO AGENT fix
      above); the useTmux/launchTerminal half was already done, above.
- [x] Launcher: revive = tmux (7325876, 23 Aug — `SessionLauncher.resume()`
      now calls `resumeTmux`, live-verified: zero Terminal.app windows opened,
      real tmux pane confirmed, dispatch into the revived session confirmed).
- [x] Launcher: PATH/env sourced from the adapter, the two trust watchers
      collapse into one (23 Aug). `HarnessAdapter` gained `pathCandidates`
      — `launchTmux`'s PATH env var now joins `adapter.pathCandidates`
      instead of one hardcoded list regardless of which harness is being
      launched; `ClaudeCodeAdapter`'s mirrors `ClaudeAgentsCLI.
      resolveBinary()`'s own search locations, `CodexAdapter`'s adds
      `~/.cargo/bin` ahead of the generic paths (codex-rs is a Rust
      workspace; unverified on this machine, included because the failure
      mode of guessing wrong is silent). The trust-watcher collapse:
      `watchForTrustPrompt(tty:)`'s AppleScript/Terminal.app branch is
      DELETED, not merely dead-flagged — it could only ever be reached for
      a non-tmux-owned tty, and `launchTmux` is the only launch path left,
      so every tty it produces is tmux-owned by construction. The function
      is now a 3-line tty→pane resolver in front of the one remaining
      loop (`watchForTrustPrompt(pane:)`), where before there were two
      full `TrustPromptWatcher.watch` invocations, one per transport.
      836/836 tests green, 2 new (`HarnessAdapterTests`, pathCandidates).
- [x] Coordinator split (23 Aug). `Coordinator.swift` was 1,321 lines mixing
      three concerns — announcing, replying, sweeping — in one file.
      `SessionSweep` extracted as a real, injectable type (new file,
      `SessionSweep.swift`): the sweep's `private nonisolated(unsafe) static
      var` state (watched sessions, probe-failure clock, heartbeat) is now
      instance state behind an `NSLock`, with a `.shared` default matching
      the old static's one-memory-per-process behavior. This is the piece
      the audit named directly — "sweep statics become injectable —
      resetSweepStateForTesting is the smell" — and it is fixed exactly
      that way: `SweepTests.swift`'s ~25 call sites now construct a fresh
      `SessionSweep()` per test instead of calling a global reset.
      Announcer and ReplyPipeline went a smaller distance, deliberately:
      split into `Coordinator+Announcer.swift` (571 lines: prepareNext,
      nextToAnnounce/nextToReplay, waiting, announceNext, summarize,
      speak, the PreparedSummaries-adjacent logic) and `Coordinator+
      ReplyPipeline.swift` (396 lines: replyTarget, submitReply,
      confirmAndSend, cancelSend, dispatch) as `extension Coordinator`
      blocks, not separate injected types — every method in both groups
      shares `store`, `agents`, `attachments`, and most of `Coordinator`'s
      other stored properties throughout, so a real type-level split would
      mean duplicating that dependency list across two new initializers
      (or redesigning how they're threaded) rather than a one-file-per-
      concern move. `Coordinator.swift` itself is now 162 lines: the
      struct, its stored properties (including `PreparedSummaries`, kept
      here since Swift extensions cannot add stored properties to a
      different file), and `init`. Zero public API changed — every
      existing `Coordinator(...)` construction and every `.announceNext()`/
      `.submitReply()`/etc. call site compiles and behaves unchanged; this
      was purely internal reorganization plus the one real behavior-
      preserving type extraction. 842/842 tests green.
- [~] App lane P1-9 (sequenced, drills green per step)
      - [x] P1, dead code + the pose bug fix (23 Aug): `StateLegend.
        SpeakTier` deleted (write-only — set at 9 construction sites,
        read at none, its own doc comment already said "nothing consults
        it yet"); `PlacardRowView`/`PaneLinkRowView` deleted from
        `StatusHUD.swift` (private, zero instantiation sites — superseded
        by `SplitPlacardRowView` and never cleaned up); the orphaned
        `VoiceRowView` doc comment (misplaced ahead of the dead
        `PaneLinkRowView` it used to sit beside) moved to the type it
        actually describes; open-issues.md #27 (the duplicate
        `case "settings":`) fixed — the stale first case deleted, the
        second (which already explained in its own doc comment why it
        was the intended one) survives as the sole case. `tools/replay`'s
        four one-off `goal-replay-*.json` outputs untracked and
        gitignored, same gap `/tools/replay/runs/`/`reports/` already
        covered, just not this specific output shape.
        `Earcons.clearOldNotifications`, also named in the audit's dead
        list, was NOT deleted — read its own doc comment first: it is a
        deliberate one-line no-op-after-first-launch cleanup for stale
        system notifications from a retired feature, not dead code, and
        deleting it removes real protection for existing installs.
        842/842 tests green; deployed and verified live (9876091):
        49/49 self-test verdicts passed, canary green.
      - [x] P2, `Widgets` struct + `TestSurface` (23 Aug). The synthesis
        report's "Widgets struct + TestSurface" turned out to be a
        compressed one-liner — the original text (commit `ebb87d9`,
        before the doc's own v2 rewrite) reads "name the coupling before
        moving," which is what this item actually is: not a feature, prep
        for P3 and P4.
        `Widgets` (new file, `Widgets.swift`, `@MainActor enum`, mirrors
        `ChromeType`'s own established pattern): houses `letterspaced`
        and `placardText`, the two loose top-level view-building helpers
        that used to sit directly in `StatusHUD.swift` — both already
        called from `PastAgentsList.swift` too, which is what made them
        safe to name first. P3's actual leaf-view targets (`DroppedItem`,
        `AudioEventRow`/`AudioEventRowView`) are untouched, still in
        `StatusHUD.swift`, waiting on P3 itself.
        `TestSurface` (new file, `TestSurface.swift`, a `@MainActor`
        protocol StatusHUD conforms to for free): sized from a real survey
        of all 25 self-test/drill functions (44 `SelfTest.report`/
        `skipped` call sites) rather than guessed — the coupling turned
        out NOT to be an access-control problem (nearly every "drive the
        panel" method a drill calls was already `internal`); what's
        actually coupled is structural, those 25 functions living inside
        StatusHUD's class body, and most of what each reads back is a
        one-off private value belonging to exactly one drill. The
        protocol carries only the genuinely reusable surface: the driving
        primitives (`showAnnouncement`, `showArming`, `showListening`,
        `showTranscribing`, `showResult`, `endCapture`, `highlight`,
        `adoptTarget`) plus one shared readout confirmed so far
        (`inkBrightLength`, relaxed from `private` to `internal` — the
        one access-modifier change this item needed). Deliberately not an
        exhaustive mirror of everything every drill touches; more joins
        as P4 actually moves drill code and finds what recurs.
        842/842 tests green; deployed and verified live (771cfc1): 49/49
        self-test verdicts passed (including the placard/strip/chip
        drills that exercise `Widgets.letterspaced`/`Widgets.
        placardText` directly), canary green.
      - [x] P3, leaf views out (23 Aug): `StatusHUD.swift` 9,186 → 7,563
        lines (1,623 moved, against the ~1,640 estimate) — every leaf
        view/data type hoisted into its own file, `StatusHUD.swift` now
        contains only the `StatusHUD` class itself. `DroppedItem` and
        `AudioEventRow`, named explicitly in the original spec, moved
        from nested (`StatusHUD.DroppedItem`/`StatusHUD.AudioEventRow`)
        to top-level — the two external references in `main.swift`
        updated to the bare names. New files: `AudioEventRow.swift`,
        `DragAndDrop.swift` (`DroppedItem`, `DropSurfaceView`,
        `TrayRowView`, `DropOverlayView`), `Labels.swift` (`DoorLabel`,
        `CardBodyLabel`), `ConsoleButton.swift`, `GridRowView.swift`,
        `Controls.swift` (`HoverBox`, `ControlsWordView`,
        `GridFooterView`, `ControlsNoteView`), `CountdownBarView.swift`,
        `VoiceRoster.swift` (`FlippedDocumentView`, `VoiceRowView`,
        `CheckView`) — grouped by real usage relationships (nesting,
        shared construction sites), not one file per type. Seven types
        relaxed from `private` to `internal` where StatusHUD.swift itself
        still constructs them across the new file boundary; two
        (`HoverBox`, `CheckView`) stayed `private`, genuinely used only
        by their sibling in the same new file.
        A real, pre-existing bug found along the way: three separate leaf
        views' doc comments (`GridRowView`, `DoorLabel`, `DropSurfaceView`)
        had been concatenated into one contiguous orphaned block ~600
        lines from all three declarations — an artifact of some earlier
        edit, invisible until each type was traced by hand. Split back
        apart and reattached to the right type, not left to travel
        further mislabeled. (Two smaller instances of the same class of
        bug were found and fixed in P1/P2 — this file has a real history
        of doc comments separating from the code they describe.)
        842/842 tests green; deploy verification below.
      - [ ] P4, drills + pose out (~3,200 lines)
      - [ ] P5, receipt/build/geometry extensions (StatusHUD core to ~2,500)
      - [ ] P6, SessionRow model + grid statics to Core, with unit tests
      - [ ] P7, main.swift extension split
      - [ ] P8, GridAssembler to Core
      - [ ] P9, Recorder/CaptureUnit/log-writer to Core
- [x] Store riders + dead-code deletions (ff98d7f, 23 Aug): `TransportKind.
      iTerm2/.wezterm/.kitty` (grep-confirmed never constructed; decode-safe
      to remove without a migration — `targetKind` is `TransportKind?` and
      this enum's `DatabaseValueConvertible` conformance is GRDB's default
      `RawRepresentable` synthesis, which decodes an unmatched raw string to
      `nil` rather than throwing), `Event.isHeadless` (zero callers,
      superseded by `SessionDiscovery.isHeadless(entrypoint:)`, already
      documented dead in open-issues.md #1), `ProcessProbe.name(of:)` (zero
      callers). **Three more store riders landed 23 Aug, same pass as the
      Launcher item above**: `HomeBase.fontSheetRoot` moved out of
      `~/.claude` (Claude Code's own shared config home, not TB's) to
      `QueueStore.supportDirectory` — the one real file it pointed at
      (`hq-fonts/kopi.css`) moved with it, not left orphaned; the
      `v12_vowelless_callsigns` migration renamed to `v17_` (it registers
      after v16 — GRDB orders by registration, not by the number in the
      name; the rename is a genuine, if low-risk, prod-data-touching
      change — flagged, not silently done, since GRDB tracks applied
      migrations by name and this makes an already-applied migration
      re-run once, harmlessly, because its body is idempotent); and
      `PrivateStorageTests.swift` added (zero coverage before, on the code
      that keeps every session's transcripts and voice recordings from
      being world-readable). **Still NOT done**: the one cache
      (StaleWhileRevalidateCache, 3 copies — main.swift, SystemVoiceCatalog,
      SessionDiscovery), the one append-only log (ArtifactStore/
      PullRequestStore), the one Core.Trace sink (11 separate
      `nonisolated(unsafe) static var trace` properties across Core, not
      8 as originally scoped — grep-recounted 23 Aug), and the
      SpokenComposition→AnnouncementLike inversion — each is a real,
      multi-file dedup, not a one-line fix, and deliberately deferred
      rather than rushed into the same sitting as the smaller riders above.
- [x] `SessionDiscovery.firstCwd` mis-homes a relocated session (5450a72,
      23 Aug — found by 2026-08-21-tb-division-of-labor: unfindable by
      project name, and `reviveCommand` would resume it in `~` rather than
      its real repo). Fixed: `firstCwd` now checks the transcript's TAIL
      first (already read by the caller for `lastMoved`, no new I/O) and
      falls back to the head's first cwd only when the tail has none — a
      session that `cd`'d into a repo and stayed there reads that repo as
      home; a brief wander into a subdirectory for one tool call, which
      never reaches the tail, still loses to the head as before.
- [x] Branch on all five documented `waitingFor` values, not just
      `dialog open` (2c2f12a, 23 Aug — 2026-08-23-agent-session-transport
      report, finding #2). `permission prompt`, `sandbox request`, and
      `worker request` were falling through to the free-text `.question`
      bucket alongside the one genuinely free-text value, `input needed` —
      a real safety gap, not just a display one, since `Readiness.
      canDispatch` used the same collapsed signal: TB would type a voice
      transcript straight at a live permission gate. `Readiness.isDialog`
      now refuses on all four hazard values (documented at Tier 1,
      code.claude.com/docs/en/agent-view); `WaitingAt` gains `.permission`,
      distinct in its copy from `.dialog` (a decision, not a modal) but
      identical in `acceptsTypedReply`.
- [x] No parallel human+tmux session, ever (c9ae20d + b8958ab, 23 Aug) — see
      "The end state" above, dual-live bullet. `SessionLauncher.
      OwnershipTransfer.toTmux` ends a hand-started process and confirms it
      is gone before resuming under tmux; wired into both
      `Coordinator.dispatch`'s `resumeTwin` and `StatusHUD.goToSession()`.
- [x] Grid: idle sessions outrank dead ones for spare floor slots (3dcf65c,
      23 Aug) — see "The end state" above, grid bullet.
- [~] tmux server survival across a macOS logout/reboot — tested for real,
      not deliberately: Robert's Mac rebooted 23 Aug and TB's own revive hung
      trying to bring a session back, forcing a manual restart outside TB.
      Two real, distinct bugs came out of this, both live-found by actually
      trying to revive real sessions after the reboot, not reasoned:
      **Bug 1, the tty race** — the tmux SERVER survived fine (launchd
      relaunches TB, TB creates a fresh one); the actual break was
      `launchTmux`'s separate `display-message` pane-tty query returning
      empty on the very first pane a freshly-created socket ever hosted.
      First fixed with a bounded retry (333595c), then fixed properly
      (5ccdb3c, same day): `new-session -d -P -F "#{pane_tty}"` prints the
      tty as part of the SAME command that creates the pane, which has
      nothing left to race against — removes the failure mode at its root
      rather than retrying around it. Not reproducible on a healthy system
      (kill server + clear socket dir + immediate new-session/display-message
      never raced), consistent with something specific to real boot-time
      system load.
      **Bug 2, the false-negative receipt** — found immediately after Bug 1's
      first fix, on a revive that had genuinely succeeded (pane confirmed
      idle and settled) but still showed "RESUMING timed out on screen."
      `revive()` had always discarded `SessionLauncher.resume()`'s result
      (`_ = SessionLauncher.resume(...)`) and never updated the receipt on
      success — invisible for as long as revive opened a Terminal.app
      window, since the window itself was the success signal (`.reviving`'s
      own doc comment says so); real the moment revive went silent
      (resumeTmux, 7325876). Fixed (779a889): new `Receipt.revived`, wired
      into both the Claude Code and Codex success paths (the Codex gap was
      identical and pre-existing, fixed in the same pass).
      Left `[~]` rather than `[x]`: both fixes address the exact failure
      modes found, but a real, deliberate reboot test to confirm they hold
      under the actual boot conditions that caused this has not been run.
- [ ] Final: preflight, full drills, merge to main, deploy verified,
      freeze lifted
