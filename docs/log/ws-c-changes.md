# WS-C / Phase 1a — state machine cleanup

Structure pass. Zero pixels changed except the sanctioned items listed under
"Behavior-affecting changes". `swift build` clean, all 65 tests pass (one new).

## Files touched

- `Sources/TranquilityApp/StateLegend.swift` — **new**. Single source of truth for
  state glyphs, state-pill labels, the hint chain, control titles, lens→NSColor
  mapping, speak tiers, menu-bar icon mapping, dictation-destination templates,
  slow-transcription copy, and the Readiness plain-words mapping.
- `Sources/TranquilityApp/StatusHUD.swift` — show* methods pull glyph/label/hint
  from StateLegend; duplicated hint chain unified into `currentActionHint()` /
  `StateLegend.actionHint`; booleans `isListening`, `isSpeakingNow` deleted and
  `awaitingConfirm` replaced by a derived predicate; transcribing elapsed
  counter + Cancel/Retry affordances added; build() colors routed through lenses.
- `Sources/TranquilityApp/main.swift` — menu-bar icon states read from the
  legend; `isCapturingAudio` wired into the ⌃⌥ gesture; `.controlDoubleTapped`
  no-op handler; Readiness plain-words at both `sessionNotReady` call sites;
  Cancel/Retry wiring for slow transcription; status-line glyphs and
  dictation-destination strings routed through the legend.
- `Sources/TranquilityApp/HotkeyMonitor.swift` — bare-⌃ double-tap detector
  emitting `.controlDoubleTapped` (0.45s window, sawOtherInput/chord-safe).
- `Sources/TranquilityApp/OnboardingWindow.swift` — permission dot references
  `StateLegend.Glyph.dot` (same character, no visual change).
- `Tests/TranquilityCoreTests/CoordinatorTests.swift` — new test
  `testSubagentStopNeverSpeaksOnItsOwn` pinning the pyramid guard.
- `docs/log/ws-c-changes.md` — this file.

## Behavior-affecting changes (everything else renders identically)

1. **Sanctioned (a), open issue #4** — the transcribing panel ticks
   "◌ Working · Ns" at 1 Hz (reads `startedAt` from the state's own payload). At
   20s it adds the hint "Taking longer than usual — your audio is safe." and shows
   Cancel / Retry buttons styled like their row-mates.
   - *Cancel* = bump `replyGeneration`, clear the recording target, return to
     idle. The in-flight network call is not interruptible, so the result is
     dropped (dictation) or its send auto-cancelled (`cancelSend` on the stale
     `readyToSend`) when it lands. Audio was durable before any network call, so
     nothing is lost.
   - *Retry* = exactly the "Retry failed transcriptions" menu path
     (`retryFailedTranscriptions`, from disk). Honest limitation: the pipeline
     cannot preempt the utterance still in flight — recovery only re-runs rows
     already in `transcriptionFailed` — so mid-flight, Retry recovers earlier
     failures and otherwise the current attempt is waited out. Flagged rather
     than improvised deeper into RecoveryChain.
   - Side effect inside the sanction: the dictation path now checks
     `replyGeneration` after transcription (it previously didn't), so a
     cancelled — or re-recorded-over — dictation is dropped instead of pasted.
2. **Sanctioned (b)** — `sessionNotReady(Readiness)` strings now name the actual
   condition in plain words (`StateLegend.plainWords(for:)`, mapping documented
   there): notRegistered → "blocked on a dialog or still starting up", targetGone
   → "its tab is gone", busy → "still working on its current turn", waiting(x) →
   "waiting on x". Both call sites (post-countdown send and immediate submit)
   plus their menu status lines.
3. **⌃⌃ double-tap** — detected in HotkeyMonitor (0.45s, disqualified by
   `sawOtherInput`; a ⌃ that grows into ⌃⌥/⌃⇧ arrives as that chord's flags via
   `formUnion`, so a chord's ⌃ can never count as a tap). Handler in main.swift
   is a pure no-op that logs "depth-1 pull: not yet implemented — WS-A". Single
   bare-⌃ taps remain no-ops, as before.
4. **Spec-directed, open issue #6** — `state.isCapturingAudio` now guards the ⌃⌥
   gesture: tapped while the mic is open (`.listening`), it logs and does
   nothing instead of starting an announcement that would record itself. This is
   work item 2 as written, but note it is a behavior change beyond the two
   sanctioned items + the ⌃⌃ no-op.

## Invariants preserved

- Panel is a non-activating `NSPanel`; never made key/activating (untouched).
- `resizeToFit` runtime layout assertions untouched.
- All state mutation still flows through `transition(to:because:)` with the same
  log format. Two transitions moved *within their methods* (`showIdle` now
  transitions before `show()`, `showPendingSend` after) so the new derived
  predicates read exactly as the old stored booleans did at render time — log
  line ordering relative to `HUD.show` shifts, rendered output does not.
- Undo-countdown semantics: open issue #8's "countdown keeps running across a
  state change" behavior is preserved by construction (the derived
  `awaitingConfirm` is `countdownTimer != nil && state.isPendingSend`; state
  entries make it false without touching the timer, same as before).
- Pyramid guard: `SubagentStop` can never speak on its own. Verified two
  existing chokepoints — the hook drops it at the source
  (`hooks/tbase-hook.sh` line ~68) and every announcement selection
  (`waitingSessions`, `latestStop`) filters `hookEvent = 'Stop'` in SQL. No new
  guard needed; the new test pins the SQL chokepoint because the spool decoder
  *would* accept a "SubagentStop" row if the hook ever let one through.
- Summarizer prompts untouched. No git commit made.

## Boolean deletions (work item 2)

- `isListening` — deleted; reads replaced by `state.isCapturingAudio`.
- `isSpeakingNow` — deleted; it was write-only (set in `announceNext`, read
  nowhere). `speech.isSpeaking` remains the real signal.
- `awaitingConfirm` — stored flag deleted; now derived
  (`countdownTimer != nil && state.isPendingSend`), which reproduces the old
  flag's every set/clear site including the "set only after show()" ordering.
- `isRecording` — **kept, with a comment.** It carries information the enum
  genuinely lacks: a recording started from the panel's Reply button does NOT
  enter `.listening` (the panel deliberately stays on the announcement; only the
  button title and hint change). Folding it into the state machine would change
  pixels. Consequence worth knowing: the new #6 guard does not cover
  button-started recordings, exactly as `isCapturingAudio`'s definition implies.

## Spec contradictions found (reported, not improvised)

1. **Open issue #7 (`canStartReply`) was NOT wired as a gesture refusal.** As
   defined (`false` for hidden/idle/preparing/listening/transcribing/settings),
   gating ⌥-hold on it would break three live behaviors: (a) dictation-to-
   clipboard when nothing is waiting — which is how #7's "transcribe then fail"
   scenario was actually fixed since the issue was filed; (b) replying from an
   idle or hidden panel within the 15-minute `replyTarget()` window; (c)
   re-recording during transcription, which `replyGeneration` exists to support.
   The predicate needs redefining before it can gate anything. Comment left at
   the `.replyBegan` site.
2. The spec's premise "gesture paths currently consult the residual booleans" is
   slightly off: main.swift's gesture code consults `recorder.isRecording` (the
   Recorder's own state) and never read the HUD booleans (they were private).
   The deletions therefore required no gesture rewiring beyond the #6 guard.
3. **⌃⌃ pairing lives in HotkeyMonitor per the spec's explicit instruction**,
   which contradicts the monitor's stated philosophy ("the monitor stays dumb
   about timing" — the ⌥⌥ window lives in main.swift). Implemented as specced,
   with a comment justifying the exception (a single bare-⌃ tap has no app
   meaning, so there is no per-tap policy to arbitrate). Cheap to move later.
4. Minor, pre-existing: on the rare failure paths where `recorder.stop()` throws
   (`recordingEnded` with no follow-up `show*`), the state machine already
   stayed stuck in `.listening` while the old booleans read false — the enum and
   booleans disagreed before this change. With the booleans gone, the derived
   reads follow the (stuck) state in that edge; recoverable via ⌥-hold or
   Dismiss, unchanged pixels. Also, the meter timer now stops itself after
   Dismiss-during-listening (state leaves `.listening`) where it previously spun
   invisibly forever — invisible-only improvement.

## Grep verification

- State glyph characters (◌ ◀ ↺ ❙❙ ▶ ⚠ ● ‹ › ✕ ✓ ✗ →) appear as string literals
  only in `StateLegend.swift` within the app module. Remaining hits elsewhere:
  two doc *comments*, and `tbase` ("audio✓/audio✗" CLI diagnostics — a separate
  executable target that cannot import the app module; not panel state glyphs).
- `isListening` / `isSpeakingNow` stored properties: zero references (the name
  `isListening` survives only as a parameter label of `StateLegend.actionHint`).
