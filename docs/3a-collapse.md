# 3a — The paint-funnel collapse

## Before / after, in ten lines

Before: nine public `show*` entry points each transitioned state, called a shared
`show(state:title:body:autoHideAfter:)` that reset most widgets (guarded by a STRING
COMPARISON against the settings pill text), then imperatively unhid and tweaked the
widgets their state owned — some after the final resize, so the window shipped sized
without them. Timers were started in whichever entry point needed them.

After: every `show*` entry point is stash-payload (`Face`) → `transition(to:)` →
`render()`. One private `render()` derives EVERY widget's text, visibility, timers,
and the auto-hide from `PanelState` + `Face`: a baseline pass writes all widgets,
then one exhaustive switch states only what each state owns. The string-compare
guard, the reset block, and `show(...)` itself are gone; nothing else paints.

## Matrix diff verdict

Selftest extended first (old code) from 5 to 10 states — preparing, working
(transcribing), pendingSend, resultOk, and waitingList added — and the extended
baseline captured before refactoring. After the refactor the per-state widget
matrix diff is **EMPTY** for all 10 states. No matrix-line format change was
needed. The legality checks (idle-over-listening REFUSED), the pendingSend
cancellability selftest, and the settings-chrome line are all identical.

Log deltas, as anticipated: the waiting list now logs
`state: settings -> idle (waiting list opened)` (state-identity fix), and
`HUD.show state=<pill text>` became `HUD.render state=<state name>`; one paint now
logs one layout line instead of up to three (single-pass resize).

## Line-count ledger (StatusHUD.swift)

| measure | before (1ade292) | after | delta |
|---|---|---|---|
| raw lines | 1242 | 1278 | **+36** (comments: render carries the architecture notes) |
| code lines (comments/blanks stripped) | 842 | 839 | **−3** |
| of which mandated selftest extension | — | ~+14 | collapse proper ≈ **−17 code** |

Repo diffstat: `StatusHUD.swift | 610 ±`, `StateLegend.swift | 22 ±` — 325
insertions, 307 deletions overall. StateLegend: 267 → 249 raw (unused
`situation(for:)` deleted; its role moved into `StatusHUD.situation()`, which can
supply the face-carried labels the enum lacks).

Also deleted as dead or made redundant by render(): `isIdle`, `voicePickerHidden`,
`listenStartedAt`, `settingsVoices`, `slowTranscriptionSurfaced` (the hidden cancel
button IS the surfaced-once latch), `onCancelTranscription`/`onRetryTranscription`
(live in `Face.transcription`), initial `isHidden` seeding in `build()` (render
writes every widget before the panel is ever ordered front), and the five
copy-pasted rounded-button style blocks (one factory).

## Behavioral deltas beyond the matrix (report these to Robert)

1. **Honest window heights in 5 states.** The old funnel resized BEFORE its entry
   points unhid late widgets, so those windows shipped too short and AppKit
   compressed the content; the `buttonsFit`/`textFits` self-checks passed because
   they measured the stale set. Now the panel is sized for everything it declares:
   idle-with-waiting 230→231, **listening 90→111**, pendingSend 138→156 (the
   countdown bar finally counted), settings 125→145 (the voice picker counted),
   waitingList 125→143 (the rows counted). Same widgets, uncompressed. If the
   compact listening pill is preferred, the honest fix is hiding empty text rows —
   a matrix-visible change that belongs to the idle-grid item.
2. **Waiting list = `.idle`**, so `canSurfaceAmbiently` is now true while the list
   is open: an arriving turn may repaint the plain idle face over it (formerly
   refused because the list borrowed `.settings`). Consistent with the list being
   the idle face's future.
3. **Settings face is now canonical** regardless of predecessor state. The old
   string-guard skipped the reset for settings, so e.g. opening settings from
   idle-with-waiting left the stale "N waiting ›" button on screen. That residue
   class is gone by construction.

## Judgment calls

- **Countdown timer stops are not exclusively in render()** (deliberate deviation
  from the brief's letter): render() is the only place it STARTS, but open issue
  #8's preserved behavior — the countdown may outlive a state change; the paths
  that end a pending send (commit, cancel, endCapture, its own expiry) say so
  themselves — means the explicit user doors still invalidate it. Folding those
  stops into render() would have changed the failure-mid-countdown behavior.
- The pendingSend hint quirk is preserved: the hint is computed before the
  countdown arms, so the undo window shows "Click Reply, or hold ⌥ to speak."
  exactly as the old funnel did.
- `.paused` has an honest render arm but is unreachable today: `setPaused()` still
  patches the speaking face in place so the highlight cannot move. Likewise
  `note()`, `highlight()`, and `recordingEnded()` remain in-place event patches,
  not state paints.
- `StateLegend.Row.showsControls` is load-bearing: render derives the action row's
  visibility from it for every state that has a Row. `SpeakTier` stays (WS-A's).
