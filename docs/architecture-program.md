# Architecture program — the gathering

Ruled 19 Aug 2026 ("I want the architecture to be significantly cleaner... let's
be very careful. We don't want to get into development hell again."), from a
six-agent full-codebase audit at bf7779e. The complete audit record with every
finding, file:line, and citation lives in HQ:
`~/Documents/deep-research/2026-08-19-tb-architecture-program/report.md`.

The diagnosis, consistent across all six auditors: the reasons are written down
at the call sites; the same fact is written down in four or five of them.
Claude Code's liveness vocabulary is parsed in four places, its transcript
dialect in five, the trust needles in three, the resume flag in two. Almost
nothing needs redesign; everything needs a home.

## How this program avoids development hell

- **Small PRs, one concern each.** Every entry below is one landable PR that
  builds green, tests green, drills green on its own. No omnibus refactors.
- **The drills are the regression net.** Nothing that the drills cover moves
  until the drill passes against the moved code. Drill-covered surfaces move
  LAST within their track.
- **Two lanes, per the multi-session protocol.** Core PRs and app-layer PRs
  proceed in parallel; the app layer keeps its one-session rule.
- **Behavior-identical refactors say so.** A PR that is a pure move carries
  "no behavior change" in its message and its diff should read that way.
- **Check this file off as PRs land** (edit the checkbox in the landing PR).

## Track A — correctness fixes (land before everything else)

- [x] A1. Watermark the delivery verification. TmuxTransport's dedupe and both
      transports' landing checks match the payload by substring against the
      ENTIRE transcript history; a short reply ("yes") that ever appeared
      before false-confirms without sending. Fix: byte-offset watermark taken
      at send() entry; only messages appended after it count. Also converts
      the whole-file re-read per poll into a tail read (audit R1 + R2).
      Regression drill: send the same payload twice; both must land.
- [ ] A2. Per-element LiveSession decode (one bad row currently nils the whole
      probe: announce noise, every reply refused). Drop + trace bad rows (R4).
- [ ] A3. One bounded Subprocess runner; ClaudeAgentsCLI.sessions() and both
      `zsh -lic` binary probes have no deadline today (R5). Collapses four
      duplicate runners and two PipeBuffers (A4).
- [ ] A4. launchTmux PATH must derive from the same candidate list
      resolveBinary honors; today it omits ~/.claude/local, ~/.bun/bin,
      ~/.npm-global (H4).
- [ ] A5. GO TO AGENT for tmux agents (attach fallback) + alive-tab guard on
      SessionLauncher.focus (the 19 Aug misfire shape survives there) + the
      resume tmux twin (R3).
- [ ] A6. QueueStore.reapAudio: per-row do/catch so a thrown update cannot
      leave a deleted file recorded as present.
- [ ] A7. ElevenLabs player joins the generationQueue lock discipline.
- [ ] A8. Wire ObjCExceptionFirewall at the installTap site, or delete the
      target. Built for a documented crash; called nowhere.
- [ ] A9. StatusHUD.pose(): duplicate `case "settings"` makes the honest
      fixture unreachable (app lane).
- [x] A10. (rides A1) TranscriptWatcher tail-from-watermark.

## Track B — the gathering

### Core lane
- [ ] B1. (= A2+A3) infrastructure dedupe + shared `classify(LiveSession?) ->
      Readiness` used by both transports.
- [x] B2. (= A1) verification watermark, so the adapter never inherits the
      substring predicate as contract.
- [ ] B3. Extract `ClaudeCodeLiveness` + `ClaudeCodeTranscripts` behind
      protocols; the five hand-rolled JSONL parsers (TranscriptArchive,
      TranscriptTitles, SessionDiscovery classifiers, SessionActivity,
      TranscriptWatcher) consume one implementation.
- [ ] B4. Extract `ClaudeCodeLaunch`: binary candidates, default args,
      resumeArguments(sessionId:) AS A FUNCTION (Codex resumes via subcommand,
      a suffix string is the wrong shape), trust needles, env. One generic
      trust watcher over injected read()/press(). Delete reviveCommand's
      second `--resume` copy.
- [ ] B5. `HarnessAdapter` protocol: liveSessions()?, transcripts, launch,
      trustPrompt?, hooks?, capabilities (queuesInputMidTurn, echoesPaste,
      promptGlyph, registersWithLiveness, hasHooks), processCommandMatches.
      Capabilities are named honestly per harness; the multi-harness survey's
      one documented regret is an interface method that silently means
      different things per backend.
- [ ] B6. Coordinator split: Announcer / ReplyPipeline / SessionSweep (sweep
      statics become an injectable instance; resetSweepStateForTesting is the
      smell that says so).
- [ ] B7. Store riders: one StaleWhileRevalidateCache (3 copies today), one
      AppendOnlyAgentLog (ArtifactStore + PullRequestStore), one Core.Trace
      sink (8 nonisolated(unsafe) statics), SpokenComposition depends on an
      AnnouncementLike protocol not on Coordinator, fontSheetRoot moves out of
      ~/.claude, PrivateStorage gets tests.
- [ ] B8. Tooling riders: tbase send shares the Coordinator's target
      resolution (today it drops the 12s readiness grace), hook-config
      generated from HookManifest.expected, usage() covers all commands,
      exit-code contract documented, capture-health-alert unpins the plugin
      version path, tools/replay one-offs gitignored.

### App lane (one session at a time; every PR gated on --selftest-hud)
- [ ] P1. Delete dead code (list in the HQ record §4) + A9.
- [ ] P2. `Widgets` struct + `TestSurface` (name the coupling before moving).
- [ ] P3. Leaf views out (~1,640 lines; hoist DroppedItem/AudioEventRow).
- [ ] P4. Drills + pose out via TestSurface (~3,200 lines).
- [ ] P5. Receipt/build/geometry extensions; StatusHUD core lands ~2,500.
- [ ] P6. SessionRow model + grid statics -> Core, with the first unit tests
      for banding/verbs/contrast; drop StateLegend's blanket @MainActor.
- [ ] P7. main.swift extension split (+Gestures/+Announce/+Reply/+Sessions/
      +Menu/+DeepLinks/+Wiring/+SelfTests).
- [ ] P8. GridAssembler -> Core (sessionRowsNow, lampAndReason, blockedOnYou,
      tabTitle) + unify the twice-written dispatch-outcome->copy mapping.
- [ ] P9. Recorder/CaptureUnit/log writer -> Core. Main-actor fixes ride their
      nearest PR: async buffered logger (P9), async drill settles (P4),
      Permissions async AppleScript (P1-sized), Recorder IO off the gesture
      path (P9), resolveReplyContext pid off-main (P7).
- [ ] P10. Transport conditionality: Permissions.isRequired(transport), the
      Terminal-naming strings, goToSession routed through onGoToSession,
      frontmost-suppression via a transport predicate.

## Track C — Codex as a peer harness (gated on evidence)

- [ ] C0. GATE: run the live validation battery against a Codex TUI in tmux
      (registration-equivalent, composer echo check, two-step injection, busy
      queue, long payload with quotes, copy-mode ambush, exact-once churn),
      exactly as was done for the tmux transport before it was built. No
      adapter code before this passes. Codex 0.144.6 is installed and
      authenticated on this machine; 177 rollouts confirm busy/answered derive
      from the rollout tail (task_started/task_complete pairs).
- [ ] C1. CodexAdapter after B5: liveness = processAlive + rollout tail;
      transcripts = rollout JSONL (session_meta/response_item/event_msg);
      resume = ["resume", id] subcommand; trust needle "Do you trust the
      contents of this directory?"; hooks = notify turn-complete only, and the
      adapter WRAPS the existing notify program (the slot is already owned by
      Codex Computer Use on this machine), never claims it.
- [ ] C2. Decision recorded: both harnesses ride the same tmux closed loop.
      Codex app-server (better busy/idle fidelity than Claude Code has
      anywhere) stays shelved as a future status upgrade because a second
      transport would undercut interchangeability; revisit only with evidence.

## Untouched, by standing ruling

The sdk-cli exclusion (robots stay out of the grid), typing fails closed, the
one-Return retry, window-per-agent dissolves only WITH the tmux default flip,
bundle id stays com.robertnowell.voice-dispatch (TCC).
