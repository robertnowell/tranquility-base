# The simplification pass — red-pen rulings, applied

Baseline 92ba8dc (identity re-ruled: title-led, callsign second, AGENTS
strip, Face.placardOverride), 148 Core tests green. App layer only —
PanelState, StateLegend, StatusHUD, main.swift — no Core commit. Every
change net-simpler; no toggles, no flags. Ledger for the pass:
**+364 / −437 across 4 files (net −73)**, with the deletions all
load-bearing UI (faces, buttons, hint chains) and the insertions mostly
doc comments, the CountdownBarView, and ruling 14's return-to-grid.

## Deletions, ruling by ruling

1. **The Sent face is dead.** `showResult` is failure-only; `PanelState
   .result(ok:)` lost its flag (`.result` = failure, log name
   `result.failed`); `Situation.sent` and the success auto-hide
   machinery (`hideWorkItem`) are gone. Success after the countdown says
   nothing: status line + log; the direct-dispatch and dictation
   successes (`Sent:`/`Queued:`/`Typed into X`/`Copied to clipboard`)
   now end with `endCapture` + immediate return to the grid. The
   `admits` guard that refused a late success receipt over live speech
   died with the face — there is no success receipt left to refuse.
2. **The Paused face is dead.** ⇧ still toggles pause, but as an AUDIO
   behavior only (the hotkey closure calls `speech.togglePause()` and
   nothing else); the frozen speaking card — karaoke highlight stopped
   mid-word — IS the pause indication. `setPaused`, the "❙❙ Paused"
   pill, `pausedHint`/`speakingHint`, and glyphs ❙❙ ↺ are deleted.
   **Enum hygiene:** `PanelState.paused` is deleted outright, not
   merely unrendered — no transition ever entered it (setPaused patched
   labels in place), so the case was a lie in the state table.
   `Situation.paused` and the render arm went with it.
3. **Hands-free ✕/✓ dead code deleted.** `discardButton` /
   `sendCheckButton` were created and toggled but never attached to any
   view hierarchy — invisible since the stack rework. Deleted along
   with `Face.handsFree`, the `showListening(handsFree:)` parameter,
   `checkTapped`, and the `handsfree` pose. Chords cover both actions
   (⌃⇧ discard, ⌥ tap / release send).
4. **Catch-up: traced, dead, deleted.** The only caller that ever
   passed `isCatchUp: true` was the pose driver's `catchup` pose;
   production `showAnnouncement` call sites (announce, depth-1,
   selftest-speak) never set it, and Core's "catch-up" comments refer to
   brief durability, not this flag. Verdict: **unreachable in
   practice** → folded into `.speaking` (the `catchUp` associated value,
   `Situation.catchingUp`, glyph ↺, and the pose are deleted). Cursor
   semantics live in Core's heardThrough watermark and are untouched.
5. **The path line is dead.** `identify(pid:cwd:)` ("kopi/promotions",
   "worktree: X") and the `identity` stash deleted from every face.
6. **Per-card hints are dead, with no replacement.** `StateLegend
   .actionHint` ("Click Reply, or hold ⌥ to speak." and its whole
   chain), `currentActionHint`, and the identity-prefixed hint plumbing
   are deleted. Cards get no hint line; `note()` survives for event
   feedback (degraded voice, slow-transcription notice). The grid's
   single bottom key line stays — **flagged on probation** in
   StateLegend; if it goes, nothing chord-teaching remains anywhere.

## Chrome

7. **Button rows are dead.** The `rounded()` lozenge factory, Reply
   (with its `\r` key equivalent — not ported; chords are the
   interface), and Dismiss buttons are deleted, along with
   `hud.onReply`/`onStopReply` and StatusHUD's `isRecording` flag
   (they existed for the Reply button alone). `Row.showsControls` is
   deleted; the action row's visibility is now computed — visible
   exactly when one of its quiet actions is. **The one surviving
   button: "Go to session"**, restyled quiet (borderless, palette ink,
   no lozenge), still shown wherever the target has a live pid,
   listening included.
8. **Context actions are quiet text.** "Don't send" (readback),
   "Cancel"/"Retry" (slow-transcribing only, surfaced by the elapsed
   ticker at 20s exactly as before). Transcribing's Reply button died
   with ruling 7.
9. **Readback**: placard `→ READBACK` via placardOverride (routing
   glyph — the words are about to travel; same mechanism as the ladder
   pills). The countdown bar is a new `CountdownBarView`: one linear
   CABasicAnimation across the whole window in `Palette.ready` green —
   the 30 Hz step-timer is dead; a single one-shot timer fires the
   send. Exactly one negative: quiet-text "Don't send". The Dismiss
   button left this face (and every face); ⌃⇧ still tears down.
10. **Depth-1**: 92ba8dc's ladder rungs already name every pull on the
    pill — `◀ FINDINGS` / `◀ SOLUTION` / `◀ WHY` via placardOverride.
    That convention WINS; no second "WHY" convention was invented. The
    `depth1` pose now shows `◀ WHY` (the rung main.swift actually
    sends), sourced from `SpokenComposition.RungKind`.

## Identity (rebased on 92ba8dc)

11. **Identity in mono on every face.** `Face.title` is the displayed
    identity — whatever 92ba8dc's `tabDisplayName` chain produces —
    rendered `monospacedSystemFont(13, semibold)` in ink, matching the
    grid rows; the topic joins the same line in the REGULAR face
    (system 12, secondary), one attributed string so the pair truncates
    together. Readback's title is now the target label (was "Your
    reply"); the listening pill stays mono. Judgment call: the empty
    state's "Tranquility Base" title rides the same mono slot — it is the
    app's own identity, and a second title style for one face is
    exactly the kind of chrome this pass deletes.
12. **needs-you in amber**: the placard text itself renders in
    `Palette.fault` — flat, calm, no second device (the "and/or" was
    read as pick-one; the 3px edge stays unbuilt).
13. **Listening dot in channel green**: the pill's ● renders
    `Palette.ready` (mic open = go), target text still chrome.

## Flow

14. **Return to the grid after speech.** REVERSED 12 Aug (Robert, live:
    "it should stay on the agent unless I drive it forward"). This ruling
    was made three days after the isPaused hang shipped, so on the
    ElevenLabs path it was never experienced until 11 Aug fixed the hang;
    first real exposure reversed it. A finished spoken card now dwells
    until a gesture moves it. The dictation receipt (ruling 5) keeps its
    auto-return. Original text follows for the record: when an
    announcement or ⌃⌃ pull finishes speaking and no gesture follows
    within 4s, the panel returns to the idle grid
    (`scheduleReturnToGrid` in main.swift).
    Cancelled by ANY gesture (first line of `handle()`) and by every
    new announcement; the work item additionally guards on the panel
    still being `.speaking`, and both schedule sites guard
    `!Task.isCancelled` so a superseding gesture's cancel can never be
    undone by a late schedule. Mid-speech remains chord-driven.
    **Proposal, not built:** a cheap non-destructive mid-speech back
    exists — clicking the AGENTS strip label (or any dead area of the
    panel) could stop audio and show the grid without dismissing the
    turn, since `showIdleGrid` is already the "stopped, still unread"
    surface. Worth ruling on before wiring a click target.

## Tests

`swift build` and `swift test` green. **No tests pinned the deleted
faces**: the App target (PanelState/StateLegend/StatusHUD) has no test
target by design — all 148 baseline tests are TranquilityCore, and
this pass touches no Core file. (The suite reads 149 at commit time:
a sibling session's in-flight MESSAGE-rung work adds one Core test in
the same working tree; not part of this commit.) The deleted faces
were pinned instead by `--selftest-hud` (updated: `resultOk` case
removed, matrix columns reply/discard/check dropped, dontSend added)
and by the pose driver (poses `catchup`, `paused`, `sent`, `handsfree`
removed).

## Verification

- `--selftest-hud`: all remaining states + both legality checks pass
  (idle-over-listening refused; pendingSend cancellable for life).
- Re-posed into scratchpad `state-shots-v2/`: grid, empty, preparing,
  speaking, depth1, listening, transcribing, transcribing-slow,
  readback, needsyou, settings — readback shows the frozen 40% green
  bar + quiet "Don't send"; depth1 shows `◀ WHY`; needsyou shows the
  amber placard; listening shows the green dot; slow-transcribing shows
  quiet Cancel/Retry (pose fix: the pose now recomputes action-row
  visibility after unhiding them, as the live ticker does).
- bundle.sh → pkill → relaunch: single instance verified, live grid
  renders (`rowH=40 cols=20/flex/aux133 singleLine=true`).

## Judgment calls

- **Dictation success feedback** ("Typed into X", "Copied to
  clipboard") now rides the status line only, per the blanket "the Sent
  face dies entirely" — the clipboard copy no longer gets a visual
  receipt. If that proves too quiet in practice, the grid-note channel
  (`showIdleGrid(note:)`) is the sanctioned place, not a card.
- **`.pendingSend` maps to no Situation** — the READBACK placard is the
  pill, so `Situation.sendingTo` is deleted rather than kept as a dead
  fallback.
- **Countdown freeze in poses**: CA animations outlive timer
  invalidation, so the pose driver pins the fill via
  `CountdownBarView.freeze(fraction:)` — a still photograph must not
  animate.
- **Sibling-session hygiene**: the working tree carried a concurrent
  session's in-flight MESSAGE-rung + menu-bar-presence work (Core,
  tbase, tests, and four hunks in main.swift). This commit is
  hunk-scoped to this pass's rulings only; the sibling's hunks remain
  uncommitted for their own session to land.
